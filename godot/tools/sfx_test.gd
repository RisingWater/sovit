extends SceneTree

# 菜单音效门槛：素材能加载、不循环、UIKit 真的把按钮接上了、静音可切。
#
# 为什么查"接上了"：音效是靠 UIKit 静态字段注入的，一旦注入时机不对
# （例如在 add_child 之后才赋值），按钮就静默地没有声音 —— 不报错、不崩溃。

const CFG := "user://hud.cfg"

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("SFX TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var had_cfg := FileAccess.file_exists(CFG)
	var backup := FileAccess.get_file_as_string(CFG) if had_cfg else ""

	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	var sfx = node.get_node_or_null("Sfx")
	if sfx == null:
		_fail("main 没有创建 Sfx 节点")
		return
	if UIKit.sfx == null:
		_fail("UIKit.sfx 没有注入 —— 所有按钮都会静默无声")
		return
	if UIKit.sfx != sfx:
		_fail("UIKit.sfx 指向的不是 main 创建的那个 Sfx")
		return

	# 三个音效池都要有内容且不循环
	for pair in [["click", sfx._click], ["switch", sfx._switch]]:
		var pool: Array = pair[1]
		if pool.is_empty():
			_fail("音效池为空：%s（素材没加载上）" % pair[0])
			return
		var st: AudioStream = (pool[0] as AudioStreamPlayer).stream
		if st == null:
			_fail("音效没有流：%s" % pair[0])
			return
		if st is AudioStreamOggVorbis and st.loop:
			_fail("音效被导入成循环：%s" % pair[0])
			return

	# 播放不能报错
	sfx.click()
	sfx.switch_sfx()
	await process_frame

	# 按钮必须真的连上了音效回调
	var b := UIKit.button("测试", true)
	# 悬停音已移除，只查点击
	if not b.mouse_entered.get_connections().is_empty():
		_fail("悬停音效已移除，但按钮还连着 mouse_entered")
		return
	if b.pressed.get_connections().is_empty():
		_fail("UIKit 造的按钮没有连点击音效")
		return
	b.free()

	# 静音开关
	var before: bool = sfx.is_muted()
	var after: bool = sfx.toggle_mute()
	if after == before:
		_fail("静音开关没有翻转")
		return
	sfx.toggle_mute()

	# 还原配置，门禁不留副作用
	if had_cfg:
		var fw := FileAccess.open(CFG, FileAccess.WRITE)
		fw.store_string(backup)
		fw.close()
	elif FileAccess.file_exists(CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))

	print("SFX TEST 音效池 click=%d switch=%d 按钮已接 ✅（悬停音已移除）" % [
		sfx._click.size(), sfx._switch.size()])
	print("SFX TEST RESULT: PASS")
	quit(0)
