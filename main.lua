local function notify(str)
	ya.notify({
		title = "Archivemount",
		content = str,
		timeout = 2,
		level = "info",
	})
end

local function fail(s, ...)
	ya.notify({ title = "Archivemount", content = string.format(s, ...), timeout = 3, level = "error" })
end

-- Default config values.
local default_config = {
	keep_orig_backup = true,
	verify_content = true,
	max_wait_time = 60,
}

local get_config = ya.sync(function(state)
	return state.config or default_config
end)

-- Basename of the user's shell (e.g. "zsh", "bash"), used everywhere we
-- need to run something through a real login-capable shell instead of
-- Lua's io.popen default. Falls back to "sh" if $SHELL isn't set, and
-- tolerates $SHELL not containing a "/" at all.
local shell_env = os.getenv("SHELL") or "/bin/sh"
local Shell_value = shell_env:match(".*/(.*)") or shell_env

local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

-- `fusermount -u` only detaches the mountpoint from the kernel's view; the
-- archivemount (FUSE) process behind it can still be flushing pending
-- writes back to the actual archive file for a moment afterward. Reading
-- the archive (e.g. with bsdtar) before that flush finishes can see a
-- partially-written/corrupt-looking file even though nothing is actually
-- wrong. This polls for the specific archivemount process tied to
-- `tmp_file` to disappear from the process table before we touch the
-- archive, instead of assuming it's done the moment fusermount returns.
local function wait_for_archivemount_exit(tmp_file, max_wait_time)
	max_wait_time = tonumber(max_wait_time) or default_config.max_wait_time
	local attempts = math.max(1, math.floor(max_wait_time / 0.1))
	for _ = 1, attempts do -- e.g. 600 × 0.1s = 60s at the default max_wait_time of 60
		local child =
			Command("pgrep"):arg("-af"):arg("archivemount"):stdout(Command.PIPED):stderr(Command.PIPED):spawn()

		if child then
			local out = child:wait_with_output()
			if out and not out.stdout:find(tmp_file, 1, true) then
				return true -- archivemount for this mount point is gone
			end
		end

		Command("sleep"):arg("0.1"):spawn():wait()
	end

	return false -- timed out
end

local selected_files = ya.sync(function()
	local tab, paths = cx.active, {}
	for _, u in pairs(tab.selected) do
		paths[#paths + 1] = tostring(u)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

-- ---------------------------------------------------------------------
-- Command execution
-- ---------------------------------------------------------------------

-- Spawns `cmd_args` through the user's shell (Shell_value -c) and waits
-- for it to finish. Returns:
--   ok      - true only if the process exited 0
--   output  - Command's output table ({stdout, stderr, status}), or nil if
--             the command never produced output (spawn/wait failure)
--   err     - the underlying error value, only set when output is nil
--   stage   - "spawn" | "wait" | "exit", identifying which step `err`
--             (if any) came from — lets callers give a precise message
local function run_shell(cmd_args, opts)
	opts = opts or {}
	local child, spawn_err = Command(Shell_value)
		:arg({ "-c", cmd_args })
		:cwd(opts.cwd or get_cwd())
		:stdin(opts.stdin or Command.INHERIT)
		:stdout(opts.stdout or Command.PIPED)
		:stderr(opts.stderr or Command.PIPED)
		:spawn()

	if not child then
		return false, nil, spawn_err, "spawn"
	end

	local output, wait_err = child:wait_with_output()
	if not output then
		return false, nil, wait_err, "wait"
	end

	return output.status.success, output, nil, "exit"
end

-- run_shell() wrapper for commands whose failure should be reported to the
-- user via fail() — this is the ONLY place that reports command_runner
-- failures;
local function command_runner(cmd_args, label, subject)
	label = label or "command"
	local suffix = subject and (" (" .. subject .. ")") or ""
	local ok, output, err, stage = run_shell(cmd_args)

	if stage == "spawn" then
		fail(
			"Failed to start `%s`%s (error: %s). Check that any required tools are installed and on your $SHELL's PATH.",
			label,
			suffix,
			tostring(err)
		)
		return false, err
	elseif stage == "wait" then
		fail("Cannot read `%s`%s output, error code %s", label, suffix, tostring(err))
		return false, err
	elseif not ok then
		local detail = output.stderr and output.stderr:gsub("%s+$", "") or ""
		if detail ~= "" then
			fail("`%s`%s exited with error code %s: %s", label, suffix, output.status.code, detail)
		else
			fail("`%s`%s exited with error code %s", label, suffix, output.status.code)
		end
		return false, output.status.code
	end

	return true, output
end

-- run_shell() wrapper for commands we only want the output of, silently.
-- Mirrors the old io.popen-based shell_capture: returns stdout even if the
-- command exited non-zero (callers like command_exists rely on that — a
-- missing binary is an expected, not exceptional, outcome), and returns
-- nil only if the command couldn't be run/read at all.
local function shell_capture(cmd, opts)
	local _, output = run_shell(cmd, opts)
	if not output then
		return nil
	end
	return output.stdout
end

local function command_exists(bin)
	local out = shell_capture("command -v " .. ya.quote(bin))
	return out ~= nil and out:match("%S") ~= nil
end

-- Runs `bsdtar -tf` on the archive, retrying a few times with a short delay
-- if it fails. A failure right after unmount is often the flush race above
-- rather than real corruption, so a transient error shouldn't immediately
-- be treated as "archive is broken" or "content mismatch". Returns the
-- listing text on success, or nil plus the last error output if every
-- attempt failed.
local function bsdtar_list_with_retry(path, max_attempts, delay_seconds)
	max_attempts = max_attempts or 5
	delay_seconds = delay_seconds or 0.3
	local bsdtar_cmd = "bsdtar -tf " .. ya.quote(path)
	local last_err = nil

	for attempt = 1, max_attempts do
		local ok, output = run_shell(bsdtar_cmd)
		if ok and output then
			return output.stdout
		end
		last_err = output and output.stderr or last_err
		if attempt < max_attempts then
			Command("sleep"):arg(tostring(delay_seconds)):spawn():wait()
		end
	end

	return nil, last_err
end

-- Plain (non-pattern) case-sensitive suffix check. The extension checks
-- below used to do str:find(ext .. "$"), e.g. str:find(".zip$"). Lua
-- patterns treat an unescaped "." as "match any character", not a literal
-- dot, so that accepted false positives like "archiveXzip" (any single
-- character standing in for the dot) as a valid .zip file. A plain suffix
-- comparison sidesteps the pattern engine entirely and can't misfire like
-- that.
local function has_suffix(str, suffix)
	return #str >= #suffix and str:sub(-#suffix) == suffix
end

-- Extension allow-list for the "mount" action. Split out from the old
-- dual-purpose `valid_file(path, action)` for readability: this function
-- only ever answers "is this a supported archive extension", and
-- is_mounted() below only ever answers "is this path currently mounted".
local function is_valid_archive_extension(path)
	if not path or path == "" then
		return false
	end

	local valid_extensions = {
		--rw
		".zip",
		".cbz", -- zip-based comic archive
		".tar",
		".tar.gz",
		".tgz",
		".tar.bz2",
		--ro
		".iso",
		".7z",
		".cb7", -- 7z based comic arhive
		".rar",
		".cbr", -- rar-based comic archive
	}

	for _, ext in ipairs(valid_extensions) do
		if has_suffix(path, ext) then
			return true
		end
	end
	return false
end

-- Runs `mount | grep -F path` once and reports both whether the path is
-- currently mounted and whether its actual mount options include "ro".
local function mount_info(path)
	if not path or path == "" then
		return false, false
	end

	local ok, output = run_shell("mount | grep -F " .. ya.quote(path))
	if not ok or not output or not output.stdout or output.stdout == "" then
		return false, false
	end

	-- If more than one line matched (shouldn't normally happen for a
	-- specific mountpoint path), take the last one as the current state.
	local last_line = nil
	for line in output.stdout:gmatch("[^\r\n]+") do
		last_line = line
	end

	local readonly = false
	if last_line then
		-- e.g. "archivemount on /x.tmp1a2b type fuse.archivemount (rw,nosuid,...)"
		local opts = last_line:match("%(([^()]*)%)%s*$")
		if opts then
			for opt in opts:gmatch("[^,]+") do
				if opt == "ro" then
					readonly = true
					break
				end
			end
		end
	end

	return true, readonly
end

local function file_exists(filename)
	local file = io.open(filename, "r")
	if file then
		file:close()
		return true
	else
		return false
	end
end

--Removed zip to tar rename, archivemount-ng works with zip directly

local readonly_extensions = { ".7z", ".cb7", ".rar", ".cbr", ".iso" }
local function is_readonly_format(path)
	if not path then
		return false
	end
	local path_to_lower = path:lower()
	for _, ext in ipairs(readonly_extensions) do
		if has_suffix(path_to_lower, ext) then
			return true
		end
	end
	return false
end

-- Normalizes paths
--   * backslashes -> forward slashes (zips built on Windows use "\")
--   * strips a leading "./"          (tar-style relative prefix)
--   * strips any leading "/"         (archives storing absolute-looking paths)
--   * strips duplicate internal slashes ("a//b" -> "a/b")
--   * strips trailing slash(es)      (directory marker, stripped after use)
-- Returns two values: the cleaned-up path (original casing, used for
-- display in messages) and a lowercased version (used as the comparison
-- key).
local function normalize_entry(raw)
	if not raw then
		return nil, nil
	end
	local p = raw:gsub("\\", "/")
	p = p:gsub("^%./", "")
	p = p:gsub("^/+", "")
	p = p:gsub("//+", "/")
	p = p:gsub("/+$", "")
	return p, p:lower()
end

-- Turns newline-separated text into a set (table keyed by line, true value)
-- plus a count, ignoring blank lines. Needed to parse list of files for archive content check
local function lines_to_set(text)
	local set, count = {}, 0
	if text then
		for line in text:gmatch("[^\r\n]+") do
			local entry, key = normalize_entry(line) -- added normalization
			if key and key ~= "" then
				set[key] = entry
				count = count + 1
			end
		end
	end
	return set, count
end

-- Builds a set of file paths (directories excluded) from `bsdtar -tf`
-- output, keyed by a case-folded, normalized path. Works across archive
-- formats/OSes: zip, tar, 7z, rar, iso, etc. can each mark directories
-- differently, so we check for a trailing slash *or* backslash before
-- normalizing (normalizing would otherwise strip that marker and
-- misclassify the entry as a file).
local function archive_listing_to_set(text)
	local set = {}
	if text then
		for line in text:gmatch("[^\r\n]+") do
			local is_dir = line:match("[/\\]%s*$") ~= nil
			local entry, key = normalize_entry(line)
			if key and key ~= "" and not is_dir then
				set[key] = entry
			end
		end
	end
	return set
end

local function tmp(path)
	local time_now = os.time()
	local hex_time = string.format("%x", time_now)
	local tmp_path = path .. ".tmp" .. hex_time

	local ok = command_runner("mkdir " .. ya.quote(tmp_path), "mkdir", tmp_path)
	if not ok then
		-- command_runner() already reported the failure via fail(),
		-- with tmp_path included as context — nothing more to add.
		return
	end
	return tmp_path
end

-- Unmounts and restores the pre-edit ".orig" backup over the (possibly
-- rewritten) archive, discarding any changes. Used both for an explicit
-- "discard" action and automatically when a save was requested on a mount
-- that turned out to be read-only (so nothing could have been saved anyway).
local function unmount_and_discard(tmp_file, original_file, prefix)
	local success = command_runner("fusermount -u " .. ya.quote(tmp_file), "fusermount", tmp_file)
	if success then
		local message = prefix or "Unmounted."
		if original_file then
			local orig_backup = original_file .. ".orig"
			if file_exists(orig_backup) then
				local restored, rerr = os.rename(orig_backup, original_file)
				if restored then
					message = message .. " Changes discarded — original archive restored."
				else
					fail(
						"Unmounted, but could not restore backup %s over %s: %s. Edited archive is still at %s; pre-edit copy still at %s.",
						orig_backup,
						original_file,
						tostring(rerr),
						original_file,
						orig_backup
					)
					return
				end
			else
				message = message .. " No changes were made, nothing to discard."
			end
		end
		notify(message)
	end
end

-- Runs the actual archivemount command. readonly forces -o ro regardless of
-- format, used both when the format is known-unwritable and when the user
-- explicitly requested a read-only mount via the "mount_ro" action.
-- Takes a single path (not an array) — this plugin only ever mounts one
-- file at a time (enforced by the #files > 1 check in entry()).
local function do_mount(path, readonly)
	local tmp_file = tmp(path)
	if not tmp_file then
		-- tmp() already reported the failure via fail(); nothing more to do.
		return
	end
	local mount_opts = readonly and "-o ro " or ""
	local cmd_args = "archivemount " .. mount_opts .. ya.quote(path) .. " " .. ya.quote(tmp_file)
	local success = command_runner(cmd_args, "archivemount", path)
	if success then
		local mount_message = "Mounting successful. Please unmount back the tmp file created."
		if readonly then
			mount_message = mount_message .. " Mounted READ-ONLY."
		end
		notify(mount_message)
	end
end

local function setup(state, opts)
	opts = opts or {}
	state.config = {
		keep_orig_backup = default_config.keep_orig_backup,
		verify_content = default_config.verify_content,
		max_wait_time = default_config.max_wait_time,
	}
	if opts.keep_orig_backup ~= nil then
		state.config.keep_orig_backup = opts.keep_orig_backup
	end
	if opts.verify_content ~= nil then
		state.config.verify_content = opts.verify_content
	end
	if opts.max_wait_time ~= nil then
		state.config.max_wait_time = opts.max_wait_time
	end

	local function getmp()
		local files = selected_files() -- func to give path of hovered/select files in array
		local path = files[1]

		--changing montpoint check logic to regex matching to stop mount | grep commands on each hover
		--we defined how folders are named so we can just check names here
		local is_mp = path ~= nil and path:match("%.tmp%x+$") ~= nil
		local is_archive = is_valid_archive_extension(path) -- to check if directory is a valid mountpoint or not

		local mount_text = ""
		if is_mp == true and is_archive == false then
			mount_text = " <mountpoint> "
		end
		return ui.Line(string.format("%s", mount_text))
	end

	Header:children_add(getmp, 5000, Header.Left)
end

return {
	entry = function(_, job)
		-- four args, mounting, mounting readonly, discarding and unmounting with saving
		local action = job.args[1]
		if not action then
			return
		end

		local config = get_config()

		local files = selected_files()
		if #files == 0 then
			notify("No files selected.")
			return
		elseif #files > 1 then
			fail("Only 1 file can be (un)mounted at a time")
			return
		end

		local selected = files[1]

		if action == "mount" then
			if not is_valid_archive_extension(selected) then
				fail("Selected file is not a valid/supported archive")
				return
			end

			if is_readonly_format(selected) then
				-- archivemount can't save these formats, ar least in my testing
				local answer = ya.confirm({
					pos = { "center", w = 70, h = 10 },
					title = "Read-only format detected",
					body = ui.Text(
						"archivemount can't reliably save edits to this format ("
							.. selected:match("%.[%a%d]+$")
							.. ").\nMount it read-only instead? (edits will not be possible)"
					):wrap(ui.Wrap.YES),
				})
				if not answer then
					notify("Mount cancelled.")
					return
				end
				do_mount(selected, true)
				return
			end

			do_mount(selected, false)
		elseif action == "mount_ro" then
			if not is_valid_archive_extension(selected) then
				fail("Selected file is not valid/supported archive")
				return
			end
			do_mount(selected, true)
		elseif action == "unmount" then
			-- `selected` is the mountpoint here (the ".tmp<hex>" directory
			-- the user is unmounting), not the original archive.
			local mount_point = selected

			local mounted, mount_is_ro = mount_info(mount_point)
			if not mounted then
				fail("Selected file is not valid for unmounting")
				return
			end

			local success_message = "Unmounting successful"

			-- Strip the ".tmp<hex>" suffix to recover the original archive path.
			local original_file = mount_point:match("^(.*)%.tmp%x+$")

			-- Read-only mounts (whether the format forced it, e.g. .7z/.rar,
			-- or the user chose "mount_ro" on an otherwise-writable format
			-- like .zip) can't have changed, so just unmount and remove the
			-- tmp dir — no point running content verification or backup
			-- cleanup against a mount nothing could have written to.
			if mount_is_ro then
				local success = command_runner("fusermount -u " .. ya.quote(mount_point), "fusermount", mount_point)
				if success then
					notify("Unmounted (read-only mount, no changes were possible).")
				end
				local deleted, err2 = os.remove(mount_point)
				if not deleted then
					fail("Cannot delete tmp file %s, error code %s", mount_point, err2)
				end
				return
			end

			-- Removing .Trash folder in case yazi deletes to trash. Non-fatal:
			-- command_runner() already notifies on failure, and unmounting
			-- proceeds regardless — leftover trash dirs don't block it.
			local trash_cleanup_cmd = "find "
				.. ya.quote(mount_point)
				.. " -maxdepth 1 -type d \\( -iname '.Trash-*' -o -iname '.Trash' \\) -exec rm -rf {} +"
			command_runner(trash_cleanup_cmd, "trash cleanup", mount_point)

			-- checking content of mounted filesystem to match in to content of archive
			local verify_available = config.verify_content and command_exists("bsdtar") --bsdtar, because it supports all formats
			local pre_set, pre_count
			if verify_available then
				-- `find . -type f` is POSIX-portable on both linux and mac; the "./" prefix
				-- it produces is already stripped by normalize_entry.
				local find_cmd = "cd " .. ya.quote(mount_point) .. " && find . -type f"
				local pre_listing = shell_capture(find_cmd)
				pre_set, pre_count = lines_to_set(pre_listing)
			end

			local success = command_runner("fusermount -u " .. ya.quote(mount_point), "fusermount", mount_point)
			if success then
				local verification_skipped = false

				-- `fusermount -u` returning doesn't guarantee archivemount has
				-- finished writing pending changes back to the archive file —
				-- give it a moment to actually exit before reading the archive.
				-- Only worth waiting for if we're actually going to verify.
				if verify_available and not wait_for_archivemount_exit(mount_point, config.max_wait_time) then
					fail(
						"archivemount process for %s did not exit in time after unmounting; skipping content verification to avoid a false mismatch.",
						mount_point
					)
					verify_available = false
					verification_skipped = true
				end

				-- checking if content of mounted file system matches content of array won't check empty folders and symlinks
				local verified_ok = true -- base state = true
				if verify_available and original_file and pre_set then
					local archive_listing, bsdtar_err = bsdtar_list_with_retry(original_file)
					if not archive_listing then
						verification_skipped = true
						success_message = success_message
							.. string.format(
								". (Skipped content verification: bsdtar could not read the archive after several attempts — %s)",
								(bsdtar_err and bsdtar_err:gsub("%s+$", "")) or "unknown error"
							)
					else
						local archive_set = archive_listing_to_set(archive_listing)

						local missing, extra = {}, {}
						for key, display_name in pairs(pre_set) do
							if not archive_set[key] then
								missing[#missing + 1] = display_name
							end
						end
						for key, display_name in pairs(archive_set) do
							if not pre_set[key] then
								extra[#extra + 1] = display_name
							end
						end

						if #missing > 0 or #extra > 0 then
							verified_ok = false
							local msg = string.format(
								"Archive contents don't match the mount! %d missing, %d extra.",
								#missing,
								#extra
							)
							if #missing > 0 then
								table.sort(missing)
								msg = msg .. " Missing: " .. table.concat(missing, ", ", 1, math.min(3, #missing))
								if #missing > 3 then
									msg = msg .. string.format(" (+%d more)", #missing - 3)
								end
							end
							if #extra > 0 then
								table.sort(extra)
								msg = msg .. " Extra: " .. table.concat(extra, ", ", 1, math.min(3, #extra))
								if #extra > 3 then
									msg = msg .. string.format(" (+%d more)", #extra - 3)
								end
							end
							if original_file and file_exists(original_file .. ".orig") then
								msg = msg .. " Backup kept at " .. original_file .. ".orig — NOT deleted."
							end
							fail(msg)
						else
							success_message = success_message .. string.format(". Verified: %d files match.", pre_count)
						end
					end
				elseif not verify_available then
					if not config.verify_content then
						success_message = success_message .. ". (Content verification disabled.)"
					else
						success_message = success_message .. ". (Install bsdtar to enable content verification.)"
					end
				end

				-- for settings options of .orig file removal, we check archive content now, so i added it
				if verified_ok and not verification_skipped and not config.keep_orig_backup and original_file then
					local orig_backup = original_file .. ".orig"
					if file_exists(orig_backup) then
						local removed, rm_err = os.remove(orig_backup)
						if not removed then
							fail("Could not remove backup file %s: %s", orig_backup, tostring(rm_err))
						end
					end
				elseif config.keep_orig_backup and original_file and file_exists(original_file .. ".orig") then
					success_message = success_message .. ". (.orig backup kept per config.)"
				end

				notify(success_message)
			end
			-- else: command_runner() already reported the fusermount
			-- failure via fail(), with mount_point included as context.

			local deleted, errd = os.remove(mount_point)
			if not deleted then
				fail("Cannot delete tmp file %s, error code %s", mount_point, errd)
			end
			return
		elseif action == "discard" then
			-- `selected` is the mountpoint here too.
			local mount_point = selected

			local is_mounted = mount_info(mount_point)
			if not is_mounted then
				fail("Selected file is not a valid mountpoint")
				return
			end

			-- Strip the ".tmp<hex>" suffix to recover the original archive path.
			local original_file = mount_point:match("^(.*)%.tmp%x+$")

			unmount_and_discard(mount_point, original_file)

			local deleted, errd = os.remove(mount_point)
			if not deleted then
				fail("Cannot delete tmp file %s, error code %s", mount_point, errd)
			end
			return
		else
			fail("Unknown action: %s", tostring(action))
		end
	end,
	setup = setup,
}
