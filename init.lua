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
		local extension = path:match("^.+(%..+)$")

		-- List of valid archive file extensions
		local valid_extensions = {
			".zip",
			".rar",
			".7z",
			".tar",
			".gz",
		}

		-- Check if the extension is in the list of valid extensions
		for _, ext in ipairs(valid_extensions) do
			if extension == ext then
				return true
			end
		end

		return false
	else
		-- check if the path is an unmountable path
		if not path:match("%.tmpXX%d+$") then
			return false
		end

		-- Use os.execute to run a shell command that checks if the path is mounted
		-- This example uses 'mount' command; adjust based on your needs
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

local function tmp(path)
	local count = 0
	local cmd_args = "mkdir " .. path .. ".tmpXX"

	while true do
		cmd_args = cmd_args .. count
		local output, err = commad_runner(cmd_args)
		if output then
			break
		else
			count = count + 1
		end
	end
	return path .. ".tmpXX" .. count
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
			fail("Only 1 files can be (un)mounted at a time")
			return
		end

		if action == "mount" then
			local tmp_file = tmp(files[1])
			if not valid_file(files[1], "mount") then
				fail("Selected file is not a valid archive")
				return
			end

			local cmd_args = "archivemount " .. table.concat(files, " ") .. " " .. tmp_file
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

			local cmd_args = "fusermount -u " .. tmp_file
			local success, err = commad_runner(cmd_args)
			if success then
				notify("Unmounting successful")
			end
			local deleted, err = commad_runner("rm -rf " .. tmp_file)
			if not deleted then
				fail("Cannot delete tmp file %s", tmp_file)
				return
			end
			return
		end
	end,
}
