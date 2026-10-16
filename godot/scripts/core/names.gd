class_name Names
extends RefCounted

# 由居民 id 确定性生成中文姓名（视图层，不入引擎）。

const SURNAMES := ["赵", "钱", "孙", "李", "周", "吴", "郑", "王", "冯", "陈", "褚", "卫", "蒋", "沈", "韩", "杨", "朱", "秦", "尤", "许"]
const GIVENS := ["伟", "芳", "娜", "敏", "静", "强", "磊", "洋", "勇", "艳", "杰", "娟", "涛", "明", "超", "霞", "平", "刚", "军", "丽"]

static func for_id(id: String) -> String:
	var h := 7
	for i in id.length():
		h = (h * 31 + id.unicode_at(i)) & 0x7fffffff
	# ⚠️ 名字和姓氏必须取**两段不相关的散列**。
	# 原来取的是 `h % 20` 和 `(h / 7) % 20` —— 两个下标只差一个线性变换，
	# 相邻 id 极易撞成同一个名（检视面板的「员工」列里出现过"尤强 / 许强 / 赵强"）。
	# 这里补一次整数混合（xorshift 风格），让名与姓各自独立分布。
	var g := h
	g = (g ^ (g >> 13)) & 0x7fffffff
	g = (g * 1103515245 + 12345) & 0x7fffffff
	g = (g ^ (g >> 11)) & 0x7fffffff
	var s: String = SURNAMES[h % SURNAMES.size()]
	var given: String = GIVENS[g % GIVENS.size()]
	return s + given
