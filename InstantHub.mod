return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`InstantHub` encountered an error loading the Darktide Mod Framework.")

		new_mod("InstantHub", {
			mod_script       = "InstantHub/scripts/mods/InstantHub/InstantHub",
			mod_data         = "InstantHub/scripts/mods/InstantHub/InstantHub_data",
			mod_localization = "InstantHub/scripts/mods/InstantHub/InstantHub_localization",
		})
	end,
	packages = {},
	version = "2.4.2",
}
