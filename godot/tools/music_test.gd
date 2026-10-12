extends SceneTree

# 背景音乐门槛检查：两首曲子存在、单曲不循环、切歌真的在交替。
#
# 为什么必须查 loop：如果 OGG 被导入成循环流，AudioStreamPlayer.finished 永远不触发，
# "轮流播放"就退化成单曲无限循环 —— 而且不会有任何报错，只能靠断言发现。

const EXPECTED := ["Shimmer Sill · Dawn", "Shimmer Sill · Dusk"]

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("MUSIC TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var m = load("res://scripts/ui/music.gd").new()
	root.add_child(m)
	await process_frame

	if m.TRACKS.size() != 2:
		_fail("曲目数应为 2，实际 %d" % m.TRACKS.size())
		return

	var p: AudioStreamPlayer = m.get_node_or_null("MusicPlayer")
	if p == null:
		_fail("没有 MusicPlayer 节点")
		return
	if not p.playing:
		_fail("没有在播放")
		return
	if not (p.stream is AudioStreamOggVorbis):
		_fail("流的类型不是 AudioStreamOggVorbis：%s" % p.stream.get_class())
		return
	# 关键：单曲不能循环，否则 finished 不触发
	if p.stream.loop:
		_fail("流被导入成循环，finished 不会触发，切歌失效")
		return

	# 交替顺序
	var first: String = m.current_track_name()
	if first != EXPECTED[0]:
		_fail("首曲应为 %s，实际 %s" % [EXPECTED[0], first])
		return
	for i in 4:
		m._play_next()
		await process_frame
		var want: String = EXPECTED[(i + 1) % 2]
		var got: String = m.current_track_name()
		if got != want:
			_fail("第 %d 次切歌应为 %s，实际 %s" % [i + 1, want, got])
			return

	# 静音开关
	var before: bool = m.is_muted()
	var after: bool = m.toggle_mute()
	if after == before:
		_fail("静音开关没有翻转")
		return
	m.toggle_mute()   # 还原

	print("MUSIC TEST 曲目=", m.TRACKS.size(), " 首曲=", first, " 切歌=OK 静音=OK")
	print("MUSIC TEST RESULT: PASS")
	quit(0)
