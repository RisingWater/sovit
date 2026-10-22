# 美术素材清单（Godot 工程）

> 由 `godot/scripts/**`、`godot/tools/**` 全量通读整理：游戏会加载的美术素材都在下表，
> 「代码引用」列写的是**加载入口**（文件:行），没有入口的就是在库未用（也照列，状态写在引用列）。
> **2026-10 立绘重出**：21 张新批（z-image-turbo 白底生成 + BiRefNet 抠图）→ alpha bbox 自适应裁 5:7 → 640×896 整批入库，
> 含新加 `gareth` 与 12 位统治者；`docs/art/npc/` 已删（归档进 `docs/art/game/03_portraits/`）。
> **2026-10 清理**：引擎里没用的素材已整体删除（商品程序化兜底 `goods/`、多余的 Kenney tile、旧版 `nav_btn_*`、`compass`、`tiny/farm.png`、10px 字体），本表与 `godot/assets/`、`docs/art/game/` 同步；缺商品图标不再回滚旧图，直接显示**亮品红方块**（`good_icons.gd`）。

**分类**（前五类是需求给定的，后面按工程实际补充）：
游戏标题 · 背景（含 9-slice 面板/按钮底纹与地图底图）· 立绘（含世界小人）· UI图标 · 按钮 · UI装饰 · 建筑贴图 · 场景图块 · 光标；字体 / 音频与未引用素材分在附录。

| 分类 | 条目数 |
|---|---|
| 游戏标题 | 3 |
| 背景 | 4 |
| 立绘 | 25 |
| UI图标 | 250 |
| 按钮 | 5 |
| UI装饰 | 7 |
| 建筑贴图 | 56 |
| 场景图块 | 3 |
| 光标 | 5 |

## 主表

| 编号 | 素材作用 | 分类 | Asset 位置 | 代码引用 |
|---|---|---|---|---|
| 1 | 游戏标题 Logo（标题页右上角那枚） | 游戏标题 | `godot/assets/ui/logo_title.png` | title_screen.gd:68；tools/title_test.gd:31 |
| 2 | 游戏应用图标（窗口 / exe 图标，project.godot 的 config/icon） | 游戏标题 | `godot/assets/ui/icon.png` | project.godot → config/icon |
| 3 | 游戏应用图标的 Windows .ico 版（打包 exe 用，同图不同格式） | 游戏标题 | `godot/assets/ui/icon.ico` | export_presets.cfg:32（application/icon） |
| 4 | 王国地图 / 外交面板底图（羊皮纸手绘，1536×952 webp；贸易面板同一张） | 背景 | `godot/assets/ui/map/kingdom_map_bare.webp` | panel_map.gd:27；panel_trade.gd:209 |
| 5 | 米黄纸面板 / 按钮 9-slice 底纹（T_PANEL_CREAM、T_BTN）；小地图日期框的木框也是它（minimap_widget.gd:92） | 背景 | `godot/assets/ui/tile_0033.png` | ui_kit.gd:250（UIKit.tile/box） |
| 6 | 按钮按下 / 选中态 9-slice 底纹（T_BTN_ACTIVE） | 背景 | `godot/assets/ui/tile_0034.png` | ui_kit.gd:250（UIKit.tile/box） |
| 7 | HUD 深色石板面板底纹（T_PANEL_DARK，压暗后盖在亮地图上） | 背景 | `godot/assets/ui/tile_0036.png` | ui_kit.gd:250（UIKit.tile/box） |
| 8 | 顾问团立绘：塞巴斯蒂安（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/sebastian.png` | cast.gd:57；panel_portrait.gd:54 |
| 9 | 顾问团立绘：阿尔文（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/alvin.png` | cast.gd:57；panel_portrait.gd:54 |
| 10 | 顾问团立绘：雷纳德（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/reynard.png` | cast.gd:57；panel_portrait.gd:54 |
| 11 | 顾问团立绘：伊莎贝拉（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/isabella.png` | cast.gd:57；panel_portrait.gd:54 |
| 12 | 顾问团立绘：薇拉（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/vera.png` | cast.gd:57；panel_portrait.gd:54 |
| 13 | 顾问团立绘：露娜（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/luna.png` | cast.gd:57；panel_portrait.gd:54 |
| 14 | 顾问团立绘：瑟拉菲娜（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/serafina.png` | cast.gd:57；panel_portrait.gd:54 |
| 15 | 顾问团立绘：米拉（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/milla.png` | cast.gd:57；panel_portrait.gd:54 |
| 16 | 顾问团立绘：加雷斯（对话 / 面板立绘；640×896 透明底，新批重出） | 立绘 | `godot/assets/portraits/gareth.png` | cast.gd:57；panel_portrait.gd:54 |
| 17 | 剧情立绘：奥德里克三世（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/adderick.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 18 | 剧情立绘：阿尔伯特（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/albert.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 19 | 剧情立绘：伯纳德（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/bernard.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 20 | 剧情立绘：塞德里克（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/cedric.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 21 | 剧情立绘：狄奥多（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/theodore.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 22 | 剧情立绘：埃德蒙（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/edmund.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 23 | 剧情立绘：弗雷德里克（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/frederick.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 24 | 剧情立绘：艾瑟琳（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/aislin.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 25 | 剧情立绘：巴图尔（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/batur.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 26 | 剧情立绘：赫尔曼（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/hermann.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 27 | 剧情立绘：格里高利（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/gregory.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 28 | 剧情立绘：伊莲娜（王室 / 邻国统治者；640×896 透明底，随章节剧情接线） | 立绘 | `godot/assets/portraits/irena.png` | 已入库；content 接线后由 cast.gd:57 取用 |
| 29 | 居民小人（阶层：老板）：地图上行走的小人 / 检视面板该阶层头像 | 立绘 | `godot/assets/actors/boss.png` | world_view.gd:1570；inspector.gd:871 |
| 30 | 居民小人（阶层：中产）：地图上行走的小人 / 检视面板该阶层头像 | 立绘 | `godot/assets/actors/middle.png` | world_view.gd:1570；inspector.gd:871 |
| 31 | 居民小人（阶层：穷人）：地图上行走的小人 / 检视面板该阶层头像 | 立绘 | `godot/assets/actors/poor.png` | world_view.gd:1570；inspector.gd:871 |
| 32 | 居民小人（阶层：富人）：地图上行走的小人 / 检视面板该阶层头像 | 立绘 | `godot/assets/actors/rich.png` | world_view.gd:1570；inspector.gd:871 |
| 33 | 商品 / 服务「盔甲」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/armor.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 34 | 商品 / 服务「弓箭」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/bows.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 35 | 商品 / 服务「砖」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/brick.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 36 | 商品 / 服务「砖房」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/brick_house.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 37 | 商品 / 服务「粘土」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/clay.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 38 | 商品 / 服务「煤」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/coal.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 39 | 商品 / 服务「粗面包」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/coarse_bread.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 40 | 商品 / 服务「粗织物」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/coarse_cloth.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 41 | 商品 / 服务「粗布衣」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/coarse_clothes.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 42 | 商品 / 服务「粗面粉」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/coarse_flour.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 43 | 商品 / 服务「常服」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/common_clothes.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 44 | 商品 / 服务「棉花」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/cotton.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 45 | 商品 / 服务「家政服务」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/domestic_service.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 46 | 商品 / 服务「肉干」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/dried_meat.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 47 | 商品 / 服务「染料」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/dye.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 48 | 商品 / 服务「教育」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/education.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 49 | 商品 / 服务「娱乐」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/entertainment.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 50 | 商品 / 服务「细织物」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/fine_cloth.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 51 | 商品 / 服务「精面粉」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/fine_flour.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 52 | 商品 / 服务「木柴」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/firewood.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 53 | 商品 / 服务「鱼类」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/fish.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 54 | 商品 / 服务「亚麻」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/flax.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 55 | 商品 / 服务「草药」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/herbs.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 56 | 商品 / 服务「兽皮」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/hide.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 57 | 商品 / 服务「茅屋」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/hut.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 58 | 商品 / 服务「铁锭」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/iron.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 59 | 商品 / 服务「铁矿石」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/iron_ore.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 60 | 商品 / 服务「铁制工具」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/iron_tools.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 61 | 商品 / 服务「皮衣」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/leather_clothes.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 62 | 商品 / 服务「华服」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/luxury_clothes.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 63 | 商品 / 服务「肉类」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/meat.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 64 | 商品 / 服务「医疗」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/medical_service.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 65 | 商品 / 服务「糕点」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/pastry.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 66 | 商品 / 服务「瓷器」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/porcelain.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 67 | 商品 / 服务「药水」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/potion.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 68 | 商品 / 服务「陶器」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/pottery.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 69 | 商品 / 服务「治安」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/safety.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 70 | 商品 / 服务「熏鱼」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/smoked_fish.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 71 | 商品 / 服务「石块」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/stone.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 72 | 商品 / 服务「石制工具」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/stone_tools.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 73 | 商品 / 服务「糖」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/sugar.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 74 | 商品 / 服务「甘蔗」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/sugarcane.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 75 | 商品 / 服务「蔬菜」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/vegetable.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 76 | 商品 / 服务「武器」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/weapons.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 77 | 商品 / 服务「小麦」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/wheat.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 78 | 商品 / 服务「白面包」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/white_bread.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 79 | 商品 / 服务「木材」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/wood.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 80 | 商品 / 服务「木屋」手绘图标（64×64 为主，全 UI 唯一图标入口优先取它） | UI图标 | `godot/assets/icons/wooden_house.png` | good_icons.gd:44（GoodIcons.tex；缺图=品红方块） |
| 81 | 预言家（瑟拉菲娜）按钮 / 面板标题 | UI图标 | `godot/assets/ui/panel/ai_assist.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 82 | 预言家冷却（灰问号）状态图标 | UI图标 | `godot/assets/ui/panel/ai_assist_off.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 83 | 顶栏：建造力（人·天/日） | UI图标 | `godot/assets/ui/panel/build.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 84 | ESC 菜单：调试开关 | UI图标 | `godot/assets/ui/panel/debug.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 85 | 外交入口（预留，当前无按钮使用） | UI图标 | `godot/assets/ui/panel/diplomacy.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 86 | 顶栏：就业 | UI图标 | `godot/assets/ui/panel/employed.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 87 | ESC 菜单：退出游戏 | UI图标 | `godot/assets/ui/panel/exit.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 88 | 统计面板「财务」页签 / 左侧「财政」圆钮 | UI图标 | `godot/assets/ui/panel/finance.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 89 | ESC 菜单：读取存档 | UI图标 | `godot/assets/ui/panel/load.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 90 | 顶栏：待生效的指令数 | UI图标 | `godot/assets/ui/panel/migration.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 91 | 军事入口（预留，当前无按钮使用） | UI图标 | `godot/assets/ui/panel/military.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 92 | 顶栏：国库；检视面板：利润/金额 | UI图标 | `godot/assets/ui/panel/money.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 93 | ESC 菜单：音乐开关 | UI图标 | `godot/assets/ui/panel/music.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 94 | ESC 菜单：新游戏 | UI图标 | `godot/assets/ui/panel/new_game.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 95 | 顶栏：人口；统计「人口」页签 / 圆钮 | UI图标 | `godot/assets/ui/panel/population.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 96 | 左侧「任务」圆钮、任务面板标题、追踪条标题 | UI图标 | `godot/assets/ui/panel/quest_panel.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 97 | 顶栏：科研力；科技面板标题 | UI图标 | `godot/assets/ui/panel/research.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 98 | 科研面板（预留，当前无按钮使用） | UI图标 | `godot/assets/ui/panel/research_panel.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 99 | 统计「资源」页签 / 左侧「资源」圆钮；贸易面板兜底 | UI图标 | `godot/assets/ui/panel/resource.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 100 | 顶栏：平均满意度 | UI图标 | `godot/assets/ui/panel/satisfaction.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 101 | ESC 菜单：保存 | UI图标 | `godot/assets/ui/panel/save.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 102 | ESC 菜单：设置资源 | UI图标 | `godot/assets/ui/panel/settings.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 103 | ESC 菜单：音效开关 | UI图标 | `godot/assets/ui/panel/sfx.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 104 | 左侧「贸易」圆钮、贸易面板标题 | UI图标 | `godot/assets/ui/panel/trade.png` | ui_kit.gd:44（panel_icon/stat_icon） |
| 105 | 左侧圆钮图标（圆盘烤在图里，48×48）：「预言」（F6） | UI图标 | `godot/assets/ui/nav/ai_assist.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 106 | 左侧圆钮图标（圆盘烤在图里，48×48）：「外交」（预留，NAV_ITEMS 暂无此项） | UI图标 | `godot/assets/ui/nav/diplomacy.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 107 | 左侧圆钮图标（圆盘烤在图里，48×48）：「财政」（F3） | UI图标 | `godot/assets/ui/nav/finance.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 108 | 左侧圆钮图标（圆盘烤在图里，48×48）：「军事」（预留，NAV_ITEMS 暂无此项） | UI图标 | `godot/assets/ui/nav/military.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 109 | 左侧圆钮图标（圆盘烤在图里，48×48）：「人口」（F2） | UI图标 | `godot/assets/ui/nav/population.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 110 | 左侧圆钮图标（圆盘烤在图里，48×48）：「任务」（F5） | UI图标 | `godot/assets/ui/nav/quest_panel.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 111 | 左侧圆钮图标（圆盘烤在图里，48×48）：「科技」（F4） | UI图标 | `godot/assets/ui/nav/research.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 112 | 左侧圆钮图标（圆盘烤在图里，48×48）：「资源」（F1，进统计-资源页） | UI图标 | `godot/assets/ui/nav/resource.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 113 | 左侧圆钮图标（圆盘烤在图里，48×48）：「贸易」（F7） | UI图标 | `godot/assets/ui/nav/trade.png` | ui_kit.gd:72（nav_icon）；hud.gd:376 |
| 114 | 科技「学院」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/academy.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 115 | 科技「流水线」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/assembly_line.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 116 | 科技「制砖机械」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/brick_press.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 117 | 科技「烧砖」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/brickmaking.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 118 | 科技「加固货箱」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/cargo_hold_1.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 119 | 科技「双辕货车」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/cargo_hold_2.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 120 | 科技「驮队扩编」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/cargo_hold_3.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 121 | 科技「木作住房」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/carpentry.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 122 | 科技「糖料与染料」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/cash_crops.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 123 | 科技「粗布裁衣」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/coarse_tailoring.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 124 | 科技「粗织」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/coarse_weaving.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 125 | 科技「常服裁制」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/common_tailoring.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 126 | 科技「营造」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/construction.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 127 | 科技「起重架」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/crane.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 128 | 科技「轮作」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/crop_rotation.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 129 | 科技「腌熏」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/curing.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 130 | 科技「掘土」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/digging.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 131 | 科技「家政」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/domestic_service.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 132 | 科技「娱乐」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/entertainment.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 133 | 科技「纤维作物」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/fiber_crops.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 134 | 科技「精磨」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/fine_milling.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 135 | 科技「细织」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/fine_weaving.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 136 | 科技「薪柴」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/firewood.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 137 | 科技「渔捞」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/fishing.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 138 | 科技「治理」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/governance.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 139 | 科技「砍价的技巧v1」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/haggle_buy_1.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 140 | 科技「砍价的技巧v2」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/haggle_buy_2.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 141 | 科技「砍价的技巧v3」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/haggle_buy_3.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 142 | 科技「交易的艺术v1」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/haggle_sell_1.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 143 | 科技「交易的艺术v2」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/haggle_sell_2.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 144 | 科技「交易的艺术v3」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/haggle_sell_3.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 145 | 科技「草药」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/herbalism.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 146 | 科技「病房」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/hospital_ward.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 147 | 科技「田猎」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/hunting.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 148 | 科技「良种」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/improved_seeds.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 149 | 科技「铁制工具」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/iron_tooling.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 150 | 科技「冶铁」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/ironworking.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 151 | 科技「灌溉」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/irrigation.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 152 | 科技「窑炉改良」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/kiln_upgrade.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 153 | 科技「皮革」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/leatherwork.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 154 | 科技「华服裁制」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/luxury_tailoring.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 155 | 科技「砖石住房」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/masonry_housing.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 156 | 科技「医道」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/medicine.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 157 | 科技「民兵」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/militia.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 158 | 科技「糕点烘焙」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/pastry_baking.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 159 | 科技「制瓷」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/porcelain.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 160 | 科技「制陶」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/pottery.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 161 | 科技「预制件」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/prefab_parts.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 162 | 科技「印刷术」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/printing_press.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 163 | 科技「民生工程」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/public_works.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 164 | 科技「精炼」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/refining.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 165 | 科技「木工机械」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/sawmill_machinery.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 166 | 科技「脚手架」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/scaffolding.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 167 | 科技「学堂」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/schooling.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 168 | 科技「抄书房」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/scriptorium.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 169 | 科技「标准化」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/standardization.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 170 | 科技「邦交」卡片图标（文件名 = 科技 id）（B4 邦交批，content 未落地） | UI图标 | `godot/assets/ui/tech/statecraft.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 171 | 科技「石作」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/stonework.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 172 | 科技「铁箍钱箱」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/strongbox_1.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 173 | 科技「双锁钱柜」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/strongbox_2.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 174 | 科技「王家信用证」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/strongbox_3.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 175 | 科技「制糖」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/sugar_refining.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 176 | 科技「淬火」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/tempering.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 177 | 科技「石制工具」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/toolmaking.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 178 | 科技「通商」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/trade.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 179 | 科技「常设商队」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/trade_caravan_1.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 180 | 科技「副队随行」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/trade_caravan_2.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 181 | 科技「三队并进」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/trade_caravan_3.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 182 | 科技「车马行会」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/trade_caravan_4.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 183 | 科技「通使礼数」卡片图标（文件名 = 科技 id）（B4 邦交批，content 未落地） | UI图标 | `godot/assets/ui/tech/trade_goodwill_1.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 184 | 科技「邦交友道」卡片图标（文件名 = 科技 id）（B4 邦交批，content 未落地） | UI图标 | `godot/assets/ui/tech/trade_goodwill_2.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 185 | 科技「万国来朝」卡片图标（文件名 = 科技 id）（B4 邦交批，content 未落地） | UI图标 | `godot/assets/ui/tech/trade_goodwill_3.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 186 | 科技「培训」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/training.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 187 | 科技「兵器」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/weaponry.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 188 | 科技「白面包烘焙」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/white_baking.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 189 | 科技「作坊分工」卡片图标（文件名 = 科技 id） | UI图标 | `godot/assets/ui/tech/workshop_division.png` | ui_kit.gd:88（tech_icon）；panel_tech.gd:512 |
| 190 | 势力徽记：灰烬集会（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/ashen_circle.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 191 | 势力徽记：黑石堡（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/blackstone.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 192 | 势力徽记：瓦尔登王庭（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/court.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 193 | 势力徽记：曙光城（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/dawn.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 194 | 动作按钮：送礼（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/gift.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 195 | 势力徽记：金穗城（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/golden_ear.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 196 | 势力徽记：圣火城（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/holy_flame.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 197 | 势力徽记：圣辉教国（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/holy_see.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 198 | 势力徽记：铁王城（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/iron_crown.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 199 | 势力徽记：铁鸦堡（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/iron_rook.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 200 | 势力徽记：翡翠王国（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/jade.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 201 | 势力徽记：沙海汗国（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/khan.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 202 | 势力徽记：铁峰公国（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/peak.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 203 | 关系牌：同盟（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_ally.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 204 | 关系牌：冷淡（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_cold.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 205 | 关系牌：敌对（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_enemy.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 206 | 关系牌：友善（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_friendly.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 207 | 关系牌：中立（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_neutral.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 208 | 关系牌：尊重（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_respect.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 209 | 关系牌：附庸（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/rel_vassal.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 210 | 势力徽记：银叶部落（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/silverleaf.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 211 | 动作按钮：结盟（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/treaty.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 212 | 动作按钮：宣战（B4 外交面板专用，Godot 端尚未接线） | UI图标 | `godot/assets/ui/faction/war.png` | 未被 .gd 引用（docs/todo.md B4-5） |
| 213 | 营地标记（沙海汗国） | UI图标 | `godot/assets/ui/map/camp.png` | panel_map.gd:739；panel_trade.gd:822 |
| 214 | 地图标记「营地标记」悬停橙色高亮版 | UI图标 | `godot/assets/ui/map/camp_hover.png` | panel_map.gd:739（_icon） |
| 215 | 神殿标记（圣辉教国） | UI图标 | `godot/assets/ui/map/temple.png` | panel_map.gd:739；panel_trade.gd:822 |
| 216 | 地图标记「神殿标记」悬停橙色高亮版 | UI图标 | `godot/assets/ui/map/temple_hover.png` | panel_map.gd:739（_icon） |
| 217 | 大城标记（王都、翡翠王国） | UI图标 | `godot/assets/ui/map/town_large.png` | panel_map.gd:739；panel_trade.gd:822 |
| 218 | 地图标记「大城标记」悬停橙色高亮版 | UI图标 | `godot/assets/ui/map/town_large_hover.png` | panel_map.gd:739（_icon） |
| 219 | 中型城标记（本村城镇中心完全恢复 / 各势力首府） | UI图标 | `godot/assets/ui/map/town_medium.png` | panel_map.gd:739；panel_trade.gd:822 |
| 220 | 地图标记「中型城标记」悬停橙色高亮版 | UI图标 | `godot/assets/ui/map/town_medium_hover.png` | panel_map.gd:739（_icon） |
| 221 | 小镇标记（本村修葺过城镇中心后 / 乌尔登小城） | UI图标 | `godot/assets/ui/map/town_small.png` | panel_map.gd:739；panel_trade.gd:822 |
| 222 | 地图标记「小镇标记」悬停橙色高亮版 | UI图标 | `godot/assets/ui/map/town_small_hover.png` | panel_map.gd:739（_icon） |
| 223 | 村落标记（本村；城镇中心段位为初始时） | UI图标 | `godot/assets/ui/map/village.png` | panel_map.gd:739；panel_trade.gd:822 |
| 224 | 地图标记「村落标记」悬停橙色高亮版 | UI图标 | `godot/assets/ui/map/village_hover.png` | panel_map.gd:739（_icon） |
| 225 | 行内小金币（16×16，价格 / 国库金额前面那一枚） | UI图标 | `godot/assets/ui/coin.png` | ui_kit.gd:115（coin_icon） |
| 226 | 建造卡片：地板（砖石铺装） | UI图标 | `godot/assets/thumbs/_floor.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 227 | 建造卡片：道路 | UI图标 | `godot/assets/thumbs/_road.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 228 | 建造卡片 / 科技面板建筑缩略图：「盔甲作坊」 | UI图标 | `godot/assets/thumbs/armor_workshop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 229 | 建造卡片 / 科技面板建筑缩略图：「弓箭作坊」 | UI图标 | `godot/assets/thumbs/bow_arrow_workshop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 230 | 建造卡片 / 科技面板建筑缩略图：「砖房」 | UI图标 | `godot/assets/thumbs/brick_house.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 231 | 建造卡片 / 科技面板建筑缩略图：「砖窑」 | UI图标 | `godot/assets/thumbs/brick_kiln.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 232 | 建造卡片 / 科技面板建筑缩略图：「粘土坑」 | UI图标 | `godot/assets/thumbs/clay_pit.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 233 | 建造卡片 / 科技面板建筑缩略图：「诊所」 | UI图标 | `godot/assets/thumbs/clinic.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 234 | 建造卡片 / 科技面板建筑缩略图：「煤矿场」 | UI图标 | `godot/assets/thumbs/coal_mine.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 235 | 建造卡片 / 科技面板建筑缩略图：「粗面包房」 | UI图标 | `godot/assets/thumbs/coarse_bakery.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 236 | 建造卡片 / 科技面板建筑缩略图：「粗布衣坊」 | UI图标 | `godot/assets/thumbs/coarse_clothes_shop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 237 | 建造卡片 / 科技面板建筑缩略图：「粗面粉磨坊」 | UI图标 | `godot/assets/thumbs/coarse_mill.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 238 | 建造卡片 / 科技面板建筑缩略图：「粗织坊」 | UI图标 | `godot/assets/thumbs/coarse_weaver.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 239 | 建造卡片 / 科技面板建筑缩略图：「常服坊」 | UI图标 | `godot/assets/thumbs/common_clothes_shop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 240 | 建造卡片 / 科技面板建筑缩略图：「建筑工坊」 | UI图标 | `godot/assets/thumbs/construction_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 241 | 建造卡片 / 科技面板建筑缩略图：「棉花农场」 | UI图标 | `godot/assets/thumbs/cotton_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 242 | 建造卡片 / 科技面板建筑缩略图：「家政工坊」 | UI图标 | `godot/assets/thumbs/domestic_service.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 243 | 建造卡片 / 科技面板建筑缩略图：「肉干坊」 | UI图标 | `godot/assets/thumbs/dried_meat_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 244 | 建造卡片 / 科技面板建筑缩略图：「染料园」 | UI图标 | `godot/assets/thumbs/dye_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 245 | 建造卡片 / 科技面板建筑缩略图：「精面粉磨坊」 | UI图标 | `godot/assets/thumbs/fine_mill.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 246 | 建造卡片 / 科技面板建筑缩略图：「细织坊」 | UI图标 | `godot/assets/thumbs/fine_weaver.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 247 | 建造卡片 / 科技面板建筑缩略图：「木柴坊」 | UI图标 | `godot/assets/thumbs/firewood_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 248 | 建造卡片 / 科技面板建筑缩略图：「渔场」 | UI图标 | `godot/assets/thumbs/fishery.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 249 | 建造卡片 / 科技面板建筑缩略图：「亚麻农场」 | UI图标 | `godot/assets/thumbs/flax_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 250 | 建造卡片 / 科技面板建筑缩略图：「治安所」 | UI图标 | `godot/assets/thumbs/guard_station.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 251 | 建造卡片 / 科技面板建筑缩略图：「草药农场」 | UI图标 | `godot/assets/thumbs/herbal_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 252 | 建造卡片 / 科技面板建筑缩略图：「医院」 | UI图标 | `godot/assets/thumbs/hospital.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 253 | 建造卡片 / 科技面板建筑缩略图：「住房坊（该项已从 content 删除，遗留文件）」 | UI图标 | `godot/assets/thumbs/housing_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 254 | 建造卡片 / 科技面板建筑缩略图：「狩猎营地」 | UI图标 | `godot/assets/thumbs/hunting_camp.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 255 | 建造卡片 / 科技面板建筑缩略图：「茅屋」 | UI图标 | `godot/assets/thumbs/hut.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 256 | 建造卡片 / 科技面板建筑缩略图：「铁矿场」 | UI图标 | `godot/assets/thumbs/iron_mine.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 257 | 建造卡片 / 科技面板建筑缩略图：「铁制工具作坊」 | UI图标 | `godot/assets/thumbs/iron_tool_workshop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 258 | 建造卡片 / 科技面板建筑缩略图：「皮衣坊」 | UI图标 | `godot/assets/thumbs/leather_shop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 259 | 建造卡片 / 科技面板建筑缩略图：「伐木场」 | UI图标 | `godot/assets/thumbs/lumberjack.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 260 | 建造卡片 / 科技面板建筑缩略图：「华服坊」 | UI图标 | `godot/assets/thumbs/luxury_clothes_shop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 261 | 建造卡片 / 科技面板建筑缩略图：「糕点房」 | UI图标 | `godot/assets/thumbs/pastry_shop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 262 | 建造卡片 / 科技面板建筑缩略图：「瓷窑」 | UI图标 | `godot/assets/thumbs/porcelain_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 263 | 建造卡片 / 科技面板建筑缩略图：「药水工坊」 | UI图标 | `godot/assets/thumbs/potion_workshop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 264 | 建造卡片 / 科技面板建筑缩略图：「陶器坊」 | UI图标 | `godot/assets/thumbs/pottery_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 265 | 建造卡片 / 科技面板建筑缩略图：「采石场」 | UI图标 | `godot/assets/thumbs/quarry.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 266 | 建造卡片 / 科技面板建筑缩略图：「研究所」 | UI图标 | `godot/assets/thumbs/research_institute.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 267 | 建造卡片 / 科技面板建筑缩略图：「学校」 | UI图标 | `godot/assets/thumbs/school.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 268 | 建造卡片 / 科技面板建筑缩略图：「冶炼场」 | UI图标 | `godot/assets/thumbs/smeltery.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 269 | 建造卡片 / 科技面板建筑缩略图：「熏鱼坊」 | UI图标 | `godot/assets/thumbs/smokehouse.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 270 | 建造卡片 / 科技面板建筑缩略图：「糖坊」 | UI图标 | `godot/assets/thumbs/sugar_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 271 | 建造卡片 / 科技面板建筑缩略图：「甘蔗园」 | UI图标 | `godot/assets/thumbs/sugarcane_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 272 | 建造卡片 / 科技面板建筑缩略图：「剧院」 | UI图标 | `godot/assets/thumbs/theater.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 273 | 建造卡片 / 科技面板建筑缩略图：「石制工具作坊」 | UI图标 | `godot/assets/thumbs/tool_works.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 274 | 建造卡片 / 科技面板建筑缩略图：「城镇中心」 | UI图标 | `godot/assets/thumbs/town_center.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 275 | 建造卡片 / 科技面板建筑缩略图：「贸易市场」 | UI图标 | `godot/assets/thumbs/trade_market.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 276 | 建造卡片 / 科技面板建筑缩略图：「蔬菜农场」 | UI图标 | `godot/assets/thumbs/vegetable_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 277 | 建造卡片 / 科技面板建筑缩略图：「仓库」 | UI图标 | `godot/assets/thumbs/warehouse.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 278 | 建造卡片 / 科技面板建筑缩略图：「瞭望台」 | UI图标 | `godot/assets/thumbs/watchtower.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 279 | 建造卡片 / 科技面板建筑缩略图：「武器作坊」 | UI图标 | `godot/assets/thumbs/weapon_workshop.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 280 | 建造卡片 / 科技面板建筑缩略图：「小麦农场」 | UI图标 | `godot/assets/thumbs/wheat_farm.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 281 | 建造卡片 / 科技面板建筑缩略图：「白面包房」 | UI图标 | `godot/assets/thumbs/white_bakery.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 282 | 建造卡片 / 科技面板建筑缩略图：「木屋」 | UI图标 | `godot/assets/thumbs/wooden_house.png` | ui_kit.gd:129（UIKit.thumb）；build_bar.gd:215 |
| 283 | 速度按钮：1 倍速 | 按钮 | `godot/assets/ui/speed_1x.png` | hud.gd:122（UIKit.icon_button） |
| 284 | 速度按钮：2 倍速 | 按钮 | `godot/assets/ui/speed_2x.png` | hud.gd:122（UIKit.icon_button） |
| 285 | 速度按钮：4 倍速 | 按钮 | `godot/assets/ui/speed_4x.png` | hud.gd:122（UIKit.icon_button） |
| 286 | 速度按钮：暂停 | 按钮 | `godot/assets/ui/speed_pause.png` | hud.gd:122（UIKit.icon_button） |
| 287 | 用工滑动条把手（8×12 木身金属箍，拖动条控件） | 按钮 | `godot/assets/ui/slider_grabber.png` | ui_kit.gd:103（slider_grabber） |
| 288 | 小地图圆环拼块（四块拼成 64×64 圆环）：TL | UI装饰 | `godot/assets/ui/ring_tl.png` | minimap_widget.gd:76 |
| 289 | 小地图圆环拼块（四块拼成 64×64 圆环）：TR | UI装饰 | `godot/assets/ui/ring_tr.png` | minimap_widget.gd:76 |
| 290 | 小地图圆环拼块（四块拼成 64×64 圆环）：BL | UI装饰 | `godot/assets/ui/ring_bl.png` | minimap_widget.gd:76 |
| 291 | 小地图圆环拼块（四块拼成 64×64 圆环）：BR | UI装饰 | `godot/assets/ui/ring_br.png` | minimap_widget.gd:76 |
| 292 | 小地图村名红巾：左端折角 | UI装饰 | `godot/assets/ui/ribbon_l.png` | minimap_widget.gd:123 |
| 293 | 小地图村名红巾：中段（可重复平铺） | UI装饰 | `godot/assets/ui/ribbon_m.png` | minimap_widget.gd:123 |
| 294 | 小地图村名红巾：右端折角 | UI装饰 | `godot/assets/ui/ribbon_r.png` | minimap_widget.gd:123 |
| 295 | 地图建筑贴图：「盔甲作坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/armor_workshop.png` | world_view.gd:639（_sprite_texture） |
| 296 | 地图建筑贴图：「弓箭作坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/bow_arrow_workshop.png` | world_view.gd:639（_sprite_texture） |
| 297 | 地图建筑贴图：「砖房」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/brick_house.png` | world_view.gd:639（_sprite_texture） |
| 298 | 地图建筑贴图：「砖窑」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/brick_kiln.png` | world_view.gd:639（_sprite_texture） |
| 299 | 地图建筑贴图：「粘土坑」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/clay_pit.png` | world_view.gd:639（_sprite_texture） |
| 300 | 地图建筑贴图：「诊所」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/clinic.png` | world_view.gd:639（_sprite_texture） |
| 301 | 地图建筑贴图：「煤矿场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/coal_mine.png` | world_view.gd:639（_sprite_texture） |
| 302 | 地图建筑贴图：「粗面包房」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/coarse_bakery.png` | world_view.gd:639（_sprite_texture） |
| 303 | 地图建筑贴图：「粗布衣坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/coarse_clothes_shop.png` | world_view.gd:639（_sprite_texture） |
| 304 | 地图建筑贴图：「粗面粉磨坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/coarse_mill.png` | world_view.gd:639（_sprite_texture） |
| 305 | 地图建筑贴图：「粗织坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/coarse_weaver.png` | world_view.gd:639（_sprite_texture） |
| 306 | 地图建筑贴图：「常服坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/common_clothes_shop.png` | world_view.gd:639（_sprite_texture） |
| 307 | 地图建筑贴图：「建筑工坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/construction_works.png` | world_view.gd:639（_sprite_texture） |
| 308 | 地图建筑贴图：「棉花农场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/cotton_farm.png` | world_view.gd:639（_sprite_texture） |
| 309 | 地图建筑贴图：「家政工坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/domestic_service.png` | world_view.gd:639（_sprite_texture） |
| 310 | 地图建筑贴图：「肉干坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/dried_meat_works.png` | world_view.gd:639（_sprite_texture） |
| 311 | 地图建筑贴图：「染料园」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/dye_farm.png` | world_view.gd:639（_sprite_texture） |
| 312 | 地图建筑贴图：「精面粉磨坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/fine_mill.png` | world_view.gd:639（_sprite_texture） |
| 313 | 地图建筑贴图：「细织坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/fine_weaver.png` | world_view.gd:639（_sprite_texture） |
| 314 | 地图建筑贴图：「木柴坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/firewood_works.png` | world_view.gd:639（_sprite_texture） |
| 315 | 地图建筑贴图：「渔场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/fishery.png` | world_view.gd:639（_sprite_texture） |
| 316 | 地图建筑贴图：「亚麻农场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/flax_farm.png` | world_view.gd:639（_sprite_texture） |
| 317 | 地图建筑贴图：「治安所」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/guard_station.png` | world_view.gd:639（_sprite_texture） |
| 318 | 地图建筑贴图：「草药农场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/herbal_farm.png` | world_view.gd:639（_sprite_texture） |
| 319 | 地图建筑贴图：「医院」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/hospital.png` | world_view.gd:639（_sprite_texture） |
| 320 | 地图建筑贴图：「狩猎营地」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/hunting_camp.png` | world_view.gd:639（_sprite_texture） |
| 321 | 地图建筑贴图：「茅屋」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/hut.png` | world_view.gd:639（_sprite_texture） |
| 322 | 地图建筑贴图：「铁矿场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/iron_mine.png` | world_view.gd:639（_sprite_texture） |
| 323 | 地图建筑贴图：「铁制工具作坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/iron_tool_workshop.png` | world_view.gd:639（_sprite_texture） |
| 324 | 地图建筑贴图：「皮衣坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/leather_shop.png` | world_view.gd:639（_sprite_texture） |
| 325 | 地图建筑贴图：「伐木场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/lumberjack.png` | world_view.gd:639（_sprite_texture） |
| 326 | 地图建筑贴图：「华服坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/luxury_clothes_shop.png` | world_view.gd:639（_sprite_texture） |
| 327 | 地图建筑贴图：「糕点房」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/pastry_shop.png` | world_view.gd:639（_sprite_texture） |
| 328 | 地图建筑贴图：「瓷窑」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/porcelain_works.png` | world_view.gd:639（_sprite_texture） |
| 329 | 地图建筑贴图：「药水工坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/potion_workshop.png` | world_view.gd:639（_sprite_texture） |
| 330 | 地图建筑贴图：「陶器坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/pottery_works.png` | world_view.gd:639（_sprite_texture） |
| 331 | 地图建筑贴图：「采石场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/quarry.png` | world_view.gd:639（_sprite_texture） |
| 332 | 地图建筑贴图：「研究所」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/research_institute.png` | world_view.gd:639（_sprite_texture） |
| 333 | 地图建筑贴图：「学校」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/school.png` | world_view.gd:639（_sprite_texture） |
| 334 | 地图建筑贴图：「冶炼场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/smeltery.png` | world_view.gd:639（_sprite_texture） |
| 335 | 地图建筑贴图：「熏鱼坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/smokehouse.png` | world_view.gd:639（_sprite_texture） |
| 336 | 地图建筑贴图：「糖坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/sugar_works.png` | world_view.gd:639（_sprite_texture） |
| 337 | 地图建筑贴图：「甘蔗园」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/sugarcane_farm.png` | world_view.gd:639（_sprite_texture） |
| 338 | 地图建筑贴图：「剧院」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/theater.png` | world_view.gd:639（_sprite_texture） |
| 339 | 地图建筑贴图：「石制工具作坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/tool_works.png` | world_view.gd:639（_sprite_texture） |
| 340 | 地图建筑贴图：「城镇中心」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/town_center.png` | world_view.gd:639（_sprite_texture） |
| 341 | 地图建筑贴图：「城镇中心·修补（第二段位）」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/town_center_patched.png` | world_view.gd:639（_sprite_texture） |
| 342 | 地图建筑贴图：「城镇中心·残破（初始状态）」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/town_center_ruined.png` | world_view.gd:639（_sprite_texture） |
| 343 | 地图建筑贴图：「贸易市场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/trade_market.png` | world_view.gd:639（_sprite_texture） |
| 344 | 地图建筑贴图：「蔬菜农场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/vegetable_farm.png` | world_view.gd:639（_sprite_texture） |
| 345 | 地图建筑贴图：「仓库」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/warehouse.png` | world_view.gd:639（_sprite_texture） |
| 346 | 地图建筑贴图：「瞭望台」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/watchtower.png` | world_view.gd:639（_sprite_texture） |
| 347 | 地图建筑贴图：「武器作坊」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/weapon_workshop.png` | world_view.gd:639（_sprite_texture） |
| 348 | 地图建筑贴图：「小麦农场」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/wheat_farm.png` | world_view.gd:639（_sprite_texture） |
| 349 | 地图建筑贴图：「白面包房」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/white_bakery.png` | world_view.gd:639（_sprite_texture） |
| 350 | 地图建筑贴图：「木屋」（正面平视、透明底，底边对齐地面线） | 建筑贴图 | `godot/assets/buildings/wooden_house.png` | world_view.gd:639（_sprite_texture） |
| 351 | 树木装饰图集（16×32 跨两格，source 2，参与 y 遮挡排序） | 场景图块 | `godot/assets/tiny/deco.png` | world_view.gd:265/273/281（_build_tileset） |
| 352 | 自绘地形图集（道路 0-15 / 水面 16-47 / 桥 48-49 / 补丁 50-52，source 1） | 场景图块 | `godot/assets/tiny/extra.png` | world_view.gd:265/273/281（_build_tileset） |
| 353 | Tiny Town 原图集（草地 / 沙土 / 道具，TileSet source 0） | 场景图块 | `godot/assets/tiny/town.png` | world_view.gd:265/273/281（_build_tileset） |
| 354 | 十字准星光标（地图放置建筑，热点 7,7） | 光标 | `godot/assets/cursors/cross.png` | world_view.gd:214（_setup_cursors） |
| 355 | 默认箭头光标（热点 1,1） | 光标 | `godot/assets/cursors/default.png` | world_view.gd:214（_setup_cursors） |
| 356 | 禁止光标（不可放置 / 无权限，热点 7,7） | 光标 | `godot/assets/cursors/deny.png` | world_view.gd:214（_setup_cursors） |
| 357 | 手型光标（可点击 / 悬停，热点 5,1） | 光标 | `godot/assets/cursors/pointer.png` | world_view.gd:214（_setup_cursors） |
| 358 | 等待光标（读条 / 忙碌，热点 7,7） | 光标 | `godot/assets/cursors/wait.png` | world_view.gd:214（_setup_cursors） |

## 附录 A：字体与音频（非图片素材，同在 assets/）

| 编号 | 素材作用 | 分类 | Asset 位置 | 代码引用 |
|---|---|---|---|---|
| 359 | UI 像素主字体（12px 原生档，全 UI 唯一字体） | 字体 | `godot/assets/fonts/fusion-pixel-12px-zh_hans.ttf` | ui_kit.gd:16 |
| 360 | 王国地图英文衬线字体（地图上的地名一律英文） | 字体 | `godot/assets/fonts/libertine/LinLibertine_DR.otf` | panel_map.gd:31；tools/map_test.gd:149 |
| 361 | 开场曲（序章 intro 段落） | 音频 | `godot/assets/music/opening_fallow.ogg` | music.gd:17（INTRO_TRACK） |
| 362 | BGM·黎明（shimmer sill dawn） | 音频 | `godot/assets/music/shimmer_sill_dawn.ogg` | music.gd:12 |
| 363 | BGM·黄昏（shimmer sill dusk） | 音频 | `godot/assets/music/shimmer_sill_dusk.ogg` | music.gd:13 |
| 364 | 点击音效（按钮按下） | 音频 | `godot/assets/sfx/click.ogg` | sfx.gd:12 |
| 365 | 切换音效（Tab / 开关） | 音频 | `godot/assets/sfx/switch.ogg` | sfx.gd:13 |

## 附录 B：在库但当前未被代码引用的素材

| 编号 | 素材作用 | 分类 | Asset 位置 | 代码引用 |
|---|---|---|---|---|
| 366 | 建筑贴图源稿（生成 assets/buildings/ 的原稿，50 张；游戏不直接加载） | 源稿 | `godot/assets/building_src/*.png` | 未被 .gd 引用；scripts/import-building-sprites.py 的输入 |

## 附录 C：不在 assets/ 的美术源稿与第三方素材包（游戏打包时排除）

| 素材 | 位置 | 说明 |
|---|---|---|
| 王国地图参考图 | `docs/art/kingdom_map_reference.jpg` | 地图底图的参考 |
| ~~第三方角色 / 动物图集~~ | ~~`godot/Characters/**`~~ | **2026-10 已删**（未进 git、代码零引用） |
| ~~第三方道具图集（桶 / 书 / 箱…）~~ | ~~`godot/Props/**`~~ | **2026-10 已删**（未进 git、代码零引用） |
| ~~第三方农田 Tileset 与示例场景~~ | ~~`godot/Tilesets/**`、`Super_Retro_World_Sample_Scene.tscn`~~ | **2026-10 已删**（仅示例场景引用，主游戏不用） |

## 缺口（代码引用了、但库里没有的素材）

- **立绘**：`cast.gd` 认识 10 人，`assets/portraits/` 只有 8 张 —— **加雷斯（gareth）、艾莉丝（elise）缺立绘**；表情差分 `<人>_<表情>.png` 一张都还没有（`cast.gd:66` 会自动落回默认立绘）。
- 商品图标：48 个商品 / 服务全部有手绘版；**程序化兜底（`assets/goods/` 48 张）已删除** —— 缺图不再静默回滚旧图，`GoodIcons.tex()` 直接返回**亮品红方块**（FF00FF）并 `push_warning`。
- 科技图标：`content/technologies.json` 现有科技全部有图标，无缺口。
- 建筑 / 住房缩略图：content 里的建筑与住房全部有缩略图，无缺口。
- `assets/ui/faction/` 23 张（13 徽记 + 7 关系牌 + 3 动作）是 B4 外交面板的素材，Godot 端还没有外交面板脚本，当前无 `.gd` 引用。
- `assets/ui/tech/statecraft.png` 与 `trade_goodwill_1/2/3.png` 是 B4「邦交」批，`content/technologies.json` 还没有这 4 项，图标先进库。

## 2026-10 清理记录（从 `godot/assets/` 删除，`docs/art/game/` 同步删）

| 删除项 | 张数 | 原因 |
|---|---|---|
| `goods/*.png`（商品程序化 16×16 兜底） | 48 | 手绘 `icons/` 已全覆盖；缺图改为显示品红方块，不再回滚旧图（`good_icons.gd` 重写，`gen-art.ts` 的生成逻辑一并移除） |
| `ui/tile_*.png`（Kenney UI Pack 备件） | 158 | 只用到 tile_0033 / 0034 / 0036；`ui_kit.gd` 的 `T_STRIPE`(6) 声明未调用，连同 const 删除 |
| `ui/nav_btn_normal|hover|pressed.png` | 3 | 已被"圆盘烤在图标里"的 `ui/nav/` 取代（`gen-art.ts` 对应生成逻辑一并移除） |
| `ui/map/compass.png` | 1 | 地图标记只会按 kind 取图，compass 永不作为 kind |
| `tiny/farm.png` | 1 | `_build_tileset()` 只用 town / extra / deco 三张 |
| `fonts/fusion-pixel-10px-zh_hans.ttf` | 1 | UI 用 12px 档（`ui_kit.gd:16`） |

合计 212 个文件（含 `.import`）。`building_src/`（50 张源稿）**保留** —— `scripts/check-footprint.ts` 的占地校验以它为贴图来源；
`ui/faction/` 23 张与 B4 邦交科技 4 张**保留**（B4 接线时直接用）。
