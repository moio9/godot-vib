extends MainLoop

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var packer := PCKPacker.new()
	assert(packer.pck_start(args[1]) == OK)
	for name in ["project.godot", "main.tscn", "test.gd"]:
		assert(packer.add_file("res://" + name, args[0].path_join(name)) == OK)
	var cache_path := args[1] + ".classes.cfg"
	var cache := ConfigFile.new()
	cache.set_value("", "list", [])
	assert(cache.save(cache_path) == OK)
	assert(packer.add_file("res://.godot/global_script_class_cache.cfg", cache_path) == OK)
	assert(packer.flush() == OK)
	print("REGRESSION_PACK_READY ", args[1])

func _process(_delta: float) -> bool:
	return true
