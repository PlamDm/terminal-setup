local selected_count = ya.sync(function()
	return #cx.active.selected
end)

return {
	entry = function()
		if selected_count() ~= 2 then
			ya.notify({
				title = "Beyond Compare",
				content = "Select exactly two files or folders before comparing.",
				timeout = 5,
				level = "warn",
			})
			return
		end

		ya.emit("shell", {
			[1] = [["BCompare.exe" %s1 %s2]],
			orphan = true,
		})
	end,
}
