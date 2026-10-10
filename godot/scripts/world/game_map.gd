class_name GameMap
extends RefCounted

# 俯视方格地图：512×512，种子生成地形 + 资源节点 + 中央仓库。
# 纯数据（RefCounted），坐标与占用随游戏存档保存。

const W := 512
const H := 512
const TILE := 48

const GRASS := 0
const FOREST := 1
const STONE := 2
const CLAY := 3
const WATER := 4

var terrain := PackedByteArray()
var road := PackedByteArray()
var floor_tiles := PackedByteArray()
var floor_charge := 0
var occupied := {}          # Vector2i -> {"kind": ..., "id": ...}
var reserved := {}          # Vector2i -> true（门格与门前通行格：不可被其它建筑占用）
var warehouse := Rect2i()
var center := Vector2i()

func _init() -> void:
	var n = W * H
	terrain.resize(n)
	road.resize(n)
	floor_tiles.resize(n)
	center = Vector2i(W / 2, H / 2)
	warehouse = Rect2i(W / 2 - 2, H / 2 - 1, 4, 3)

func idx(x: int, y: int) -> int:
	return y * W + x

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H

func terrain_at(c: Vector2i) -> int:
	return terrain[idx(c.x, c.y)]

static func terrain_name(t: int) -> String:
	match t:
		FOREST: return "forest"
		STONE: return "stone"
		CLAY: return "clay"
		WATER: return "water"
		_: return "grass"

func is_water(c: Vector2i) -> bool:
	return terrain_at(c) == WATER

func generate(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.02
	noise.fractal_octaves = 3

	terrain.fill(GRASS)
	for y in H:
		for x in W:
			if noise.get_noise_2d(float(x), float(y)) > 0.18:
				terrain[idx(x, y)] = FOREST

	# 一条河
	var river_y = H / 2 + 60
	for x in W:
		var ry = river_y + int(sin(float(x) * 0.03) * 10.0)
		for dy in range(-3, 4):
			var yy = ry + dy
			if yy >= 0 and yy < H:
				terrain[idx(x, yy)] = WATER

	# 石矿 / 粘土矿脉
	for i in 6:
		_blob(rng, rng.randi_range(60, W - 60), rng.randi_range(60, H - 60), 6, STONE)
	for i in 6:
		_blob(rng, rng.randi_range(60, W - 60), rng.randi_range(60, H - 60), 6, CLAY)

	# 出生点附近保证有树林
	_blob(rng, center.x + 10, center.y - 12, 16, FOREST)
	_blob(rng, center.x - 20, center.y + 10, 14, FOREST)
	_blob(rng, center.x - 6, center.y - 24, 12, FOREST)

	# 出生点附近保证有石矿与粘土矿（不太远，方便开局）
	_blob(rng, center.x - 26, center.y - 16, 8, STONE)
	_blob(rng, center.x + 30, center.y + 14, 8, CLAY)
	_blob(rng, center.x + 24, center.y - 28, 7, STONE)
	_blob(rng, center.x - 32, center.y + 26, 7, CLAY)

	# 仓库区清成草地
	for y in range(warehouse.position.y - 2, warehouse.end.y + 2):
		for x in range(warehouse.position.x - 2, warehouse.end.x + 2):
			if in_bounds(Vector2i(x, y)):
				terrain[idx(x, y)] = GRASS

func _blob(rng: RandomNumberGenerator, cx: int, cy: int, r: int, t: int) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if x < 0 or y < 0 or x >= W or y >= H:
				continue
			var d = Vector2(float(x - cx), float(y - cy)).length()
			if d <= float(r) * (0.65 + rng.randf() * 0.5):
				terrain[idx(x, y)] = t

func cell_free(c: Vector2i) -> bool:
	return in_bounds(c) and not occupied.has(c) and not warehouse.has_point(c) and not reserved.has(c)

func terrain_ok(origin: Vector2i, fw: int, fh: int, terrains: Array) -> bool:
	for dy in fh:
		for dx in fw:
			var c = origin + Vector2i(dx, dy)
			if not in_bounds(c):
				return false
			if is_water(c):
				return false
			if not cell_free(c):
				return false
			if not terrains.is_empty() and not terrains.has(terrain_name(terrain_at(c))):
				return false
	return true

func occupy(origin: Vector2i, fw: int, fh: int, kind: String, id: String) -> void:
	for dy in fh:
		for dx in fw:
			occupied[origin + Vector2i(dx, dy)] = {"kind": kind, "id": id}

func free_cells(origin: Vector2i, fw: int, fh: int) -> void:
	for dy in fh:
		for dx in fw:
			occupied.erase(origin + Vector2i(dx, dy))

func occupied_at(c: Vector2i) -> Variant:
	return occupied.get(c, null)
