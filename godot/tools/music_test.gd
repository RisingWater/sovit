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

	# 开场曲：播完之后（剧情结束）必须**当场**切回常规轮播，不能延续到游戏里
	# （用户 2026-10-20："开场的 bgm 延续到了游戏开始，不对，应该剧情过完就切掉"）
	m.play_intro()
	await process_frame
	if m.current_track_name() != "Follow Through":
		_fail("play_intro() 之后应当放开场曲，实际 %s" % m.current_track_name())
		return
	m.end_intro()
	await process_frame
	if m.current_track_name() == "Follow Through":
		_fail("剧情结束之后开场曲还在放（应该切回常规曲）")
		return
	if not (EXPECTED as Array).has(m.current_track_name()):
		_fail("end_intro() 之后应当是常规曲，实际 %s" % m.current_track_name())
		return
	# 幂等：没在放开场曲时再调一次，不该乱切
	var keep_track: String = m.current_track_name()
	m.end_intro()
	await process_frame
	if m.current_track_name() != keep_track:
		_fail("没放开场曲时 end_intro() 不该切歌（%s → %s）" % [keep_track, m.current_track_name()])
		return

	# 静音开关
	var before: bool = m.is_muted()
	var after: bool = m.toggle_mute()
	if after == before:
		_fail("静音开关没有翻转")
		return
	m.toggle_mute()   # 还原

	print("MUSIC TEST 曲目=", m.TRACKS.size(), " 首曲=", first, " 切歌=OK 开场曲到剧情结束就切=OK 静音=OK")
	print("MUSIC TEST RESULT: PASS")
	quit(0)
