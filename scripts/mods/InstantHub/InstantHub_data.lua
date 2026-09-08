local mod = get_mod("InstantHub")

mod.data = {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "hub_caching",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "show_notifications",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "preload_hub",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "reserve_hub_server",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "preconnect_hub_server",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "mourningstar_region",
				type = "dropdown",
				default_value = "auto",
				options = {
					{ text = "mourningstar_region_auto", value = "auto" },
					{ text = "mourningstar_region_afr_south", value = "afr-south" },
					{ text = "mourningstar_region_ap_central", value = "ap-central" },
					{ text = "mourningstar_region_ap_north", value = "ap-north" },
					{ text = "mourningstar_region_ap_south", value = "ap-south" },
					{ text = "mourningstar_region_eu", value = "eu" },
					{ text = "mourningstar_region_hk", value = "hk" },
					{ text = "mourningstar_region_mei", value = "mei" },
					{ text = "mourningstar_region_sa", value = "sa" },
					{ text = "mourningstar_region_us_east", value = "us-east" },
					{ text = "mourningstar_region_us_west", value = "us-west" },
				},
			},
			{
				setting_id = "preload_psychanium",
				type = "checkbox",
				default_value = true,
			},
		}
	}
}

return mod.data
