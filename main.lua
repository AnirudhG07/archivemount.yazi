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

-- Configurable option to delete orig file
local config = {
	keep_orig_backup = true,
}

local Shell_value = os.getenv("SHELL"):match(".*/(.*)")
local state = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

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

local function command_runner(cmd_args)
	local cwd = state()
	local child, err = Command(Shell_value)
		:arg({ "-c", cmd_args })
		:cwd(cwd)
		:stdin(Command.INHERIT)
		:stdout(Command.PIPED)
		:stderr(Command.INHERIT)
		:spawn()

	if not child then
		fail("Spawn `archivemounting` failed with error code %s. Do you have `tag` installed?", err)
		return err, child
	end

	local output, err = child:wait_with_output()
	if not output then
		fail("Cannot read `archivemounting` output, error code %s", err)
		return err, child
	elseif not output.status.success and output.status.code ~= 131 then
		fail("`archivemounting` exited with error code %s", output.status.code)
		return output.status.code, output
	else
		return true, output
	end
end

local function valid_file(path, action)
	-- Check if path is not nil or empty
	if not path or path == "" then
		return false
	end
	if action == "mount" then
		-- Extract the file extension
		local valid_extensions = {
			--rw
			".zip",
			".cbz", -- zip-based comic archive
			".tar",
			".tar.gz",
			".tgz",
			".tar.bz2",
			--ro
			--			".iso",
			".7z",
			".cb7", -- 7z based comic arhive
			".rar",
			".cbr", -- rar-based comic archive
		}

		-- Function to check if the file extension matches any of the valid extensions
		local function has_valid_extension(_path)
			for _, ext in ipairs(valid_extensions) do
				if _path:find(ext .. "$") then
					return true
				end
			end
			return false
		end
		-- Extract the file extension, including compound extensions like .tar.gz
		return has_valid_extension(path)
	else
		-- Use os.execute to run a shell command that checks if the path is mounted
		local check_mount_cmd = "mount | grep " .. ya.quote(path) .. " 2>/dev/null" --ya.quote already shell-escapes the path
		local handle = io.popen(check_mount_cmd, "r")
		if handle then
			local output = handle:read("*a") -- Read the entire output
			handle:close()
			if output and output ~= "" then
				return true -- Path is mounted
			else
				return false -- Path is not mounted
			end
		end
	end
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

local function shell_capture(cmd)
	local handle = io.popen(cmd .. " 2>/dev/null")
	if not handle then
		return nil
	end
	local out = handle:read("*a")
	handle:close()
	return out
end

local function command_exists(bin)
	local out = shell_capture("command -v " .. bin)
	return out ~= nil and out:match("%S") ~= nil
end

local readonly_extensions = { ".7z", ".cb7", ".rar", ".cbr", ".iso" }
local function is_readonly_format(path)
	if not path then
		return false
	end
	local path_to_lower = path:lower()
	for _, ext in ipairs(readonly_extensions) do
		if path_to_lower:find(ext .. "$") then
			return true
		end
	end
	return false
end

-- Turns newline-separated text into a set (table keyed by line, true value)
-- plus a count, ignoring blank lines. Needed to parse list of files for archive content check
local function lines_to_set(text)
	local set, count = {}, 0
	if text then
		for line in text:gmatch("[^\r\n]+") do
			if line ~= "" then
				set[line] = true
				count = count + 1
			end
		end
	end
	return set, count
end

local function tmp(path)
	local time_now = os.time()
	local hex_time = string.format("%x", time_now)
	local tmp_path = path .. ".tmp" .. hex_time

	local cmd_args = "mkdir " .. ya.quote(tmp_path)

	local output, err = command_runner(cmd_args)
	if not output then
		fail("Cannot create tmp file %s", tmp_path)
		return
	end
	return tmp_path
end

-- Unmounts and restores the pre-edit ".orig" backup over the (possibly
-- rewritten) archive, discarding any changes. Used both for an explicit
-- "discard" action and automatically when a save was requested on a mount
-- that turned out to be read-only (so nothing could have been saved anyway).
local function unmount_and_discard(tmp_file, original_file, prefix)
	local cmd_args = "fusermount -u " .. ya.quote(tmp_file)
	local success, err = command_runner(cmd_args)
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
	local success, output = command_runner(cmd_args)
	if success then
		local mount_message = "Mounting successful. Please unmount back the tmp file created."
		if readonly then
			mount_message = mount_message .. " Mounted READ-ONLY."
		end
		notify(mount_message)
	end
end

local function setup(_, opts)
	opts = opts or {}
	if opts.keep_orig_backup ~= nil then
		config.keep_orig_backup = opts.keep_orig_backup
	end

	local function getmp()
		local files = selected_files() -- func to give path of hovered/select files in array
		local path = files[1]

		--changing montpoint check logic to regex matching to stop mount | grep commands on each hover
		--we defined how folders are named so we can just check names here
		local is_mp = path ~= nil and path:match("%.tmp%x+$") ~= nil
		local is_archive = valid_file(files[1], "mount") -- to check if directory is a valid mountpoint or not

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
			if not valid_file(selected, "mount") then
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
		end

		if action == "mount_ro" then
			if not valid_file(selected, "mount") then
				fail("Selected file is not valid/supported archive")
				return
			end
			do_mount(selected, true)
		end

		if action == "unmount" then
			-- `selected` is the mountpoint here (the ".tmp<hex>" directory
			-- the user is unmounting), not the original archive.
			local mount_point = selected

			if not valid_file(mount_point, "unmount") then
				fail("Selected file is not valid for unmounting")
				return
			end

			local cmd_args = "fusermount -u " .. ya.quote(mount_point)
			local success_message = "Unmounting successful"

			-- Strip the ".tmp<hex>" suffix to recover the original archive path.
			local original_file = mount_point:match("^(.*)%.tmp%x+$")

			-- readonly mounts just need rolder removal
			if is_readonly_format(original_file) then
				local success, err = command_runner(cmd_args)
				if success then
					notify("Unmounted (read-only mount, no changes were possible).")
				end
				local deleted, err2 = os.remove(mount_point)
				if not deleted then
					fail("Cannot delete tmp file %s, error code %s", mount_point, err2)
				end
				return
			end

			-- Removing .Trash folder in case yazi deletes to trash
			local trash_cleanup_cmd = "find "
				.. ya.quote(mount_point)
				.. " -maxdepth 1 -type d \\( -iname '.Trash-*' -o -iname '.Trash' \\) -exec rm -rf {} +"
			local trash_ok, trash_err = command_runner(trash_cleanup_cmd)
			if not trash_ok then
				fail("Could not clean up trash dirs before unmounting: %s", tostring(trash_err))
			end

			-- checking content of mounted filesystem to match in to content of archive
			local verify_available = command_exists("bsdtar") --bsdtar, because it supports all formats
			local pre_set, pre_count
			if verify_available then
				local pre_listing = shell_capture("find " .. ya.quote(mount_point) .. " -type f -printf '%P\\n'")
				pre_set, pre_count = lines_to_set(pre_listing)
			end

			local success, err = command_runner(cmd_args)
			if success then
				-- checking if content of mounted file system matches content of array won't check empty folders and symlinks
				local verified_ok = true -- base state = true
				if verify_available and original_file and pre_set then
					local archive_listing = shell_capture("bsdtar -tf " .. ya.quote(original_file))
					local archive_set, archive_count = {}, 0
					if archive_listing then
						for line in archive_listing:gmatch("[^\r\n]+") do
							local entry = line:gsub("^%./", "")
							-- Skip directory entries (trailing "/"); we only compare files.
							if entry ~= "" and not entry:match("/$") then
								archive_set[entry] = true
								archive_count = archive_count + 1
							end
						end
					end

					local missing, extra = {}, {}
					for f in pairs(pre_set) do
						if not archive_set[f] then
							missing[#missing + 1] = f
						end
					end
					for f in pairs(archive_set) do
						if not pre_set[f] then
							extra[#extra + 1] = f
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
				elseif not verify_available then
					success_message = success_message .. ". (Install bsdtar to enable content verification.)"
				end

				-- for settings options of .orig file removal, we check archive content now, so i added it
				if verified_ok and not config.keep_orig_backup and original_file then
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
			else
				fail("Unmounting failed with error code %s", err)
			end

			local deleted, errd = os.remove(mount_point)
			if not deleted then
				fail("Cannot delete tmp file %s, error code %s", mount_point, errd)
			end
			return
		end

		if action == "discard" then
			-- `selected` is the mountpoint here too.
			local mount_point = selected

			if not valid_file(mount_point, "unmount") then
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
		end
	end,
	setup = setup,
}
