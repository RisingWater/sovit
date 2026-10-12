extends Node

# 菜单音效：按钮点击 / 悬停 / 切换。
#
# 素材：Kenney "UI SFX Set"（CC0，无需署名），见 assets/sfx/License (Kenney UI SFX).txt
#
# 用一小组 AudioStreamPlayer 轮转，而不是一个播放器反复换流 ——
# 后者在连续点击时会把上一个音效掐断，听起来像丢帧。

const CLICK := "res://assets/sfx/click.ogg"
const HOVER := "res://assets/sfx/hover.ogg"
const SWITCH := "res://assets/sfx/switch.ogg"
const CFG_PATH := "user://hud.cfg"
const DEFAULT_VOLUME := 0.6
const VOICES := 4          # 每个音效的并发播放器数量

var _click: Array[AudioStreamPlayer] = []
var _hover: Array[AudioStreamPlayer] = []
var _switch: Array[AudioStreamPlayer] = []
var _ci := 0
var _hi := 0
var _si := 0
var _volume := DEFAULT_VOLUME
var _muted := false

func _ready() -> void:
	_load_cfg()
	_click = _make_pool(CLICK, VOICES)
	_hover = _make_pool(HOVER, VOICES)
	_switch = _make_pool(SWITCH, 2)

func _make_pool(path: String, n: int) -> Array[AudioStreamPlayer]:
	var out: Array[AudioStreamPlayer] = []
	var st: AudioStream = load(path)
	if st == null:
		push_error("SFX: 无法加载 " + path)
		return out
	# 音效不该被导入成循环
	if st is AudioStreamOggVorbis:
		st.loop = false
	for i in n:
		var p := AudioStreamPlayer.new()
		p.stream = st
		p.volume_db = _db()
		add_child(p)
		out.append(p)
	return out

func _db() -> float:
	if _muted or _volume <= 0.001:
		return -80.0
	return linear_to_db(_volume)

func _apply_volume() -> void:
	for pool in [_click, _hover, _switch]:
		for p in pool:
			p.volume_db = _db()

## 轮转播放：找空闲的，都忙就抢最早那个
func _fire(pool: Array[AudioStreamPlayer], idx_ref: int) -> int:
	if pool.is_empty() or _muted:
		return idx_ref
	for i in pool.size():
		if not pool[i].playing:
			pool[i].play()
			return i
	var i := idx_ref % pool.size()
	pool[i].play()
	return (i + 1) % pool.size()

func click() -> void:
	_ci = _fire(_click, _ci)

func hover() -> void:
	_hi = _fire(_hover, _hi)

func switch_sfx() -> void:
	_si = _fire(_switch, _si)

# ---- 给 UI 的接口 -----------------------------------------------------------
func is_muted() -> bool:
	return _muted

func toggle_mute() -> bool:
	_muted = not _muted
	_apply_volume()
	_save_cfg()
	return _muted

func _load_cfg() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		_volume = clampf(float(cf.get_value("sfx", "volume", DEFAULT_VOLUME)), 0.0, 1.0)
		_muted = bool(cf.get_value("sfx", "muted", false))

func _save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)   # 保留其它段（资源选择 / 音乐 / 面板位置都在这个文件里）
	cf.set_value("sfx", "volume", _volume)
	cf.set_value("sfx", "muted", _muted)
	cf.save(CFG_PATH)
