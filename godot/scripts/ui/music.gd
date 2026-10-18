extends Node

# 背景音乐：轮流播放 Shimmer Sill 的两首（Dawn / Dusk）。
#
# 素材：RPG Town Pack（Talon 目录），授权 = 免费用于任何 Godot 项目，
# **需署名** "Music: Talon Trueblood"。见 godot/assets/music/Read Me (RPG Town Pack).txt
#
# 不循环单曲，而是播完一首接下一首 —— 所以给流设 loop = false，
# 靠 AudioStreamPlayer.finished 信号切歌。

const TRACKS := [
	"res://assets/music/shimmer_sill_dawn.ogg",
	"res://assets/music/shimmer_sill_dusk.ogg",
]
## 开场剧情那首（同一套 RPG Town Pack 的第 6 首 "Follow Through"）。
## 播完由 `_play_next()` 接回常规轮播 —— 不用显式恢复。
const INTRO_TRACK := "res://assets/music/opening_fallow.ogg"
const CFG_PATH := "user://hud.cfg"
const DEFAULT_VOLUME := 0.55   # 0..1

var _player: AudioStreamPlayer
var _idx := -1
var _volume := DEFAULT_VOLUME
var _muted := false
## 现在放的是不是开场曲（`current_track_name()` 要如实报）
var _intro := false

func _ready() -> void:
	_load_cfg()
	_player = AudioStreamPlayer.new()
	_player.name = "MusicPlayer"
	_player.bus = "Master"
	# 音乐不该抢音效（本作暂无音效，先留好）
	_player.volume_db = _db(_volume)
	add_child(_player)
	_player.finished.connect(_play_next)
	_play_next()

func _db(v: float) -> float:
	# 0 -> 静音；否则线性转分贝，太小的值直接钳掉避免 -inf
	if v <= 0.001:
		return -80.0
	return linear_to_db(v)

func _apply_volume() -> void:
	if _player != null:
		_player.volume_db = _db(0.0 if _muted else _volume)

func _play_next() -> void:
	_intro = false
	_idx = (_idx + 1) % TRACKS.size()
	var st: AudioStream = load(TRACKS[_idx])
	if st == null:
		push_error("Music: 无法加载 " + TRACKS[_idx])
		return
	# 单曲不循环，播完切下一首
	if st is AudioStreamOggVorbis:
		st.loop = false
	_player.stream = st
	_player.play()

## 放开场剧情那首（用户 2026-10 指定）。
## ⚠️ 开场曲**只播到剧情结束为止**：剧情放完（或玩家跳过）由 `end_intro()` 当场切回常规轮播 ——
## 不能等这首自己播完（用户 2026-10-20："开场的 bgm 延续到了游戏开始，不对，应该剧情过完就切掉"）。
func play_intro() -> void:
	var st: AudioStream = load(INTRO_TRACK)
	if st == null:
		push_error("Music: 无法加载 " + INTRO_TRACK)
		return
	if st is AudioStreamOggVorbis:
		st.loop = false
	_intro = true
	_player.stream = st
	_player.play()

## 开场剧情结束：**立刻**切回常规轮播（下一首 Dawn / Dusk）。
##
## 幂等：没在放开场曲时什么都不做（读档 / 直接进游戏不会无缘无故切歌）。
func end_intro() -> void:
	if not _intro:
		return
	_play_next()

func _load_cfg() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		_volume = clampf(float(cf.get_value("music", "volume", DEFAULT_VOLUME)), 0.0, 1.0)
		_muted = bool(cf.get_value("music", "muted", false))

func _save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)   # 保留其它段（顶栏资源选择也在同一个文件里）
	cf.set_value("music", "volume", _volume)
	cf.set_value("music", "muted", _muted)
	cf.save(CFG_PATH)

# ---- 给 UI 的接口 -----------------------------------------------------------
func is_muted() -> bool:
	return _muted

func toggle_mute() -> bool:
	_muted = not _muted
	_apply_volume()
	_save_cfg()
	return _muted

func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	if not _muted:
		_apply_volume()
	_save_cfg()

func get_volume() -> float:
	return _volume

func current_track_name() -> String:
	if _intro:
		return "Follow Through"
	if _idx < 0:
		return ""
	var base: String = TRACKS[_idx].get_file().get_basename()
	if base == "shimmer_sill_dawn":
		return "Shimmer Sill · Dawn"
	if base == "shimmer_sill_dusk":
		return "Shimmer Sill · Dusk"
	return base
