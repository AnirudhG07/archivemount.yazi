local function notify(str)
	ya.notify({
		title = "Archivemount",
		content = str,
		timeout = 2,
		level = "info",
	})
end

local function fail(s, ...)
	ya.notify({ title = "archivemouting", content = string.format(s, ...), timeout = 3, level = "error" })
end

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

local function commad_runner(cmd_args)
	local cwd = state()
	local child, err = Command(Shell_value)
		:args({ "-c", cmd_args })
		:cwd(cwd)
		:stdin(Command.INHERIT)
		:stdout(Command.PIPED)
		:stderr(Command.INHERIT)
		:spawn()

	if not child then
		fail("Spawn `archivemouting` failed with error code %s. Do you have `tag` installed?", err)
		return err, child
	end

	local output, err = child:wait_with_output()
	if not output then
		fail("Cannot read `archivemouting` output, error code %s", err)
		return err, child
	elseif not output.status.success and output.status.code ~= 131 then
		fail("`archivemouting` exited with error code %s", output.status.code)
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
			".zip",
			".tar",
			".tar.gz",
			".tgz",
			".tar.bz2",
		}

		-- Function to check if the file extension matches any of the valid extensions
		local function has_valid_extension(path)
			for _, ext in ipairs(valid_extensions) do
				if path:find(ext .. "$") then
					return true
				end
			end
			return false
		end
		-- Extract the file extension, including compound extensions like .tar.gz
		return has_valid_extension(path)
	else
		-- Use os.execute to run a shell command that checks if the path is mounted
		local check_mount_cmd = "mount | grep '" .. path .. "' 2>/dev/null"
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

local function rename_zip_to_tar(filename)
	local zip_file = filename .. ".zip"
	local orig_file = filename .. ".zip.orig"
	local tar_file = filename .. ".tar"

	-- Check if both files exist
	if file_exists(zip_file) and file_exists(orig_file) then
		local success, err = os.rename(zip_file, tar_file)
		if not success then
			fail("Error renaming zip file: " .. err)
		end
	end
end

local function tmp(path)
	local time_now = os.time()
	local hex_time = string.format("%x", time_now)
	local tmp_path = path .. ".tmp" .. hex_time

	local cmd_args = "mkdir " .. tmp_path

	local output, err = commad_runner(cmd_args)
	if not output then
		fail("Cannot create tmp file %s", tmp_path)
		return
	end
	return tmp_path
end

local function setup()
	local function getmp()
		local files = selected_files() -- func to give path of hovered/select files in array
		local is_mp = valid_file(files[1], "unmount")
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
	entry = function(_, args)
		-- two args so far, mounting and unmounting
		local action = args[1]
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

		if action == "mount" then
			if not valid_file(files[1], "mount") then
				fail("Selected file is not a valid/supported archive")
				return
			end
			local tmp_file = tmp(files[1])
			local cmd_args = "archivemount " .. table.concat(files, " ") .. " " .. ya.quote(tmp_file)
			local success, output = commad_runner(cmd_args)
			if success then
				notify("Mounting successful. Please unmount back the tmp file created.")
			end
		end

		if action == "unmount" then
			local tmp_file = files[1]

			if not valid_file(tmp_file, "unmount") then
				fail("Selected file is not valid for unmounting")
				return
			end

			local cmd_args = "fusermount -u " .. ya.quote(tmp_file)
			local success_message = "Unmounting successful"

			local zip_index = tmp_file:find(".zip.tmp.*")
			local zip_fn = tmp_file
			if zip_index then
				zip_fn = zip_fn:sub(1, zip_index - 1)
				rename_zip_to_tar(zip_fn)
				success_message = success_message .. ". Note: Unmounted .zip file is converted to .tar"
			end

			local success, err = commad_runner(cmd_args)
			if success then
				notify(success_message)
			end

			local deleted, err = os.remove(tmp_file)
			if not deleted then
				fail("Cannot delete tmp file %s", tmp_file)
			end
			return
		end
	end,
	setup = setup,
}
