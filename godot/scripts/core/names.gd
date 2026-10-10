class_name Names
extends RefCounted

# 由居民 id 确定性生成中文姓名（视图层，不入引擎）。

const SURNAMES := ["赵", "钱", "孙", "李", "周", "吴", "郑", "王", "冯", "陈", "褚", "卫", "蒋", "沈", "韩", "杨", "朱", "秦", "尤", "许"]
const GIVENS := ["伟", "芳", "娜", "敏", "静", "强", "磊", "洋", "勇", "艳", "杰", "娟", "涛", "明", "超", "霞", "平", "刚", "军", "丽"]

static func for_id(id: String) -> String:
	var h := 7
	for i in id.length():
		h = (h * 31 + id.unicode_at(i)) & 0x7fffffff
	var s: String = SURNAMES[h % SURNAMES.size()]
	var g: String = GIVENS[(h / 7) % GIVENS.size()]
	return s + g
