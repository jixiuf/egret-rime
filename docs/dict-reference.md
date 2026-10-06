# 词库（Dictionary）参考

> 源码依据：`src/rime/dict/`（entry_collector / dict_compiler / table / prism /
> reverse_lookup_dictionary / user_dictionary / level_db）。

## 1. .dict.yaml 明文格式

```yaml
# 头部：--- 到 --- 之间的 yaml（dict_settings.cc 解析）
---
name: egret_wubi_chars   # 表名（import_tables 引用它，不带 .dict.yaml）
version: "0.1"
sort: original                   # original=按文件序 by_weight=按权重 by_frequency
columns:                         # 可选：定义正文列序（默认 1 text 2 code 3 weight）
  - text
  - code
  - weight
  - stem
import_tables:
  - dicts/egret_wubi_chars   # 支持子目录！只有这里支持
  - dicts/wb86_wangxiang_cn_dicts/base.small
vocabulary: essay                # 八股文词频表（给无 weight 词组补权）
use_preset_vocabulary: true      # 同上（旧写法）
max_phrase_length: 4
min_phrase_weight: 100
encoder:
  exclude_patterns:
    - '^z.*$'
  rules:
    - length_equal: 2            # 词长=2 时
      formula: "AaAbBaBb"        # 坐标语法见 §4
    - length_in_range: [3, 10]   # 词长 3-10 时
      formula: "AaBaCaZ"
...
```

正文（`---` 之后）每行一个词条：

```
text<TAB>code<TAB>weight<TAB>[stem]
```

- **weight 语义**：词库里的数字在编译时被 `log()` 化后存入 table.bin
  （dict_compiler.cc:257 `e->weight = log(r->weight)`；候选质量 = `exp(weight)`，
  见 translator_commons.cc Phrase 构造）。支持绝对值或百分号相对权重
  （`500%` = preset_vocabulary 权重的 5 倍，entry_collector.cc）。
  **不同来源的词库如果权重刻度不同（知频 0-1500万 vs 万象 0-1000），混在同一个
  translator 里会破坏 LM 组句与排序**——本项目已统一 log-norm 0-1000。
- stem 列：造词用词干（罕见使用）。
- `# no comment` 行之后不再解析注释列。
- 同码多词条自然按权重裁决（如 tffu: 等 780 > 徒增 502），**不要**在词库层
  硬过滤冲突词——本项目曾因过滤字全码导致 `tffu` 出不了"等"。
- 导入即合并：import_tables 的各表与主表正文合并；重复词条处理取决于
  `sort` 与编译器去重（entry_collector）。

## 2. 编译产物

`dict_compiler.cc` 总控（部署时自动调用，checksum 变化才重编译）：

| 产物 | 生成器 | 内容 |
|------|--------|------|
| `build/<dict>.table.bin` | table.cc | 码表：head→trunk→entries，权重 log float |
| `build/<prism>.prism.bin` | prism.cc | DARTS trie：拼写串 → SyllableId；含 SpellingMap（类型/可信度）、alphabet、max_key_length。**由 speller/algebra 对所有词条 code 展开后构建** |
| `build/<dict>.reverse.bin` | reverse_lookup_dictionary.cc | 词→码 反查表 |
| `build/<dict>.multiple.table.bin` | 多 packs 时 | 附加表 |

要点与陷阱：
- **prism 非确定性**：libdarts 对同 key 集合构建时，内部排序受遍历顺序影响；
  一个拼写映射多个音节时，prism 内的首选音节可能随目录/文件序而变 → 候选翻转。
  对策：词库层保证简码拼写唯一音节（ownership），或 patch librime 在 lookup
  处排序（`patches/librime-0001-dict-entry-iterator-sort-on-lookup.patch`，存档）。
- `translator/dictionary:` 与 `prism:` 键**不支持子目录路径**，静默失败。
  子目录只能通过词库头 `import_tables` 引入；根包装 .dict.yaml 必须在用户目录
  根（Rime 解析 import_tables 时以各文件自身位置解析相对路径）。
- 重编译判定：dict 文件 checksum（含 import 的子表与 vocabulary 文件）与
  schema 文件 checksum，任一变化即重建 table；prism 另受 schema checksum 影响。
  部署失败/静默回退时先核对 build/ 下产物的 md5 与文件时间。

## 3. 词典组件链路（运行时）

```
translator 配置块
  ├─ dictionary: <name>   → Dictionary(name, prism, packs)
  │     ├─ table:  <name>.table.bin    （主表）
  │     ├─ packs:  <n>.multiple.table.bin（附加表）
  │     └─ prism:  <prism>.prism.bin
  └─ user_dict: <name>.user.dict
        ├─ db_class: userdb  → <用户目录>/build/<name>.userdb/（LevelDB，二进制）
        ├─ db_class: tabledb → <用户目录>/<name>.txt（纯文本，人类可读可编辑）
        └─ db_class: stabledb→ 同上 .txt，但 OpenReadOnly()，**真只读**
        ├─ user phrase 查询（优先于静态表）
        ├─ 调频（dynamics: dynamics 模块写入 commit 时间戳/频率）
        └─ UnityTableEncoder 运行时造词（\x7fenc\x1f 前缀条目）
```

- `Memory`（gear/memory.h）是 translator 与词典生命周期的粘合层。
- 用户词典三态（**2026-10 更正**：此处原写“`tabledb` 只读”是**错的**，见 §7）：
  `enable_user_dict: false` 完全不建；`tabledb` 与 `userdb` **都可读可写**
  （只有 `stabledb` 真只读：`dict/table_db.h` 的 `StableDb::Open() → TableDb::OpenReadOnly()`）；
  区别只在**落点与读写代价**：

  | db_class | 落点 | 写入行为 | 工具/恢复 |
  |---|---|---|---|
  | `userdb` | `build/<name>.userdb/`（LevelDB） | 增量写、事务、`*.userdb.old` 备份 | `userdb_recovery_task` 损坏恢复；`rime_dict_manager` 导出 `*.userdb.txt` 快照 |
  | `tabledb` | `<用户目录>/<name>.txt`（纯文本） | 可写；`TextDb::Close()` 时**全量重写**整张表 | 人类可读、可 git 管理；无事务/无备份/无恢复 |
  | `stabledb` | 同上 `.txt` | `Update/Erase/MetaUpdate` 全被 `readonly()` 拒绝 | 官方 custom_phrase 配方用的就是这个 |

  本项目（egret_wubi / egret_wubi_py）**三个 user_dict 全部用 `tabledb`**，落点是
  用户目录根 `egret_wubi.user.dict.txt` / `egret_wubi_py_script.user.dict.txt` /
  `egret_wubi_py.user.dict.txt`（最后一个是 custom_phrase）。
- ⚠️ **坑（2026-10 踩过）**：translator 块**不写 `user_dict` 时**，librime 会用
  `dictionary` 名派生用户词典名（`user_dictionary.cc UserDictionaryComponent::Create
  (ticket)` → `Language::get_language_component`），而 `enable_user_dict` 默认 `true`
  → **加载方案（建组件）时就创建 `<dictionary>.userdb/`**，与是否触发该 translator 无关。
  本项目的多读法路由块 `wubi_route`/`py_route` 就因此多出了 `egret_wubi.userdb` /
  `egret_wubi_py.userdb`；现在两块显式复用主翻译器的 tabledb 词库（同名共享）。
  写新 translator 时：要么显式给 `user_dict`，要么显式 `enable_user_dict: false`。
- **测试前清用户词典**（`scripts/regression_test.py --clean`，只清机器会写的两本，
  不动 custom_phrase），否则历史上屏会以 user phrase 形式调频，压住词库修正
  ——本项目第 4 号坑。

## 4. 造词规则（encoder/rules）

读取位置：**词库头部的 `encoder:`**（dict settings），不是 schema！
 UnityTableEncoder 在运行时造词时按此规则用 reverse.bin 查每个字的全码。

formula 坐标语法（algo/encoder.cc）：
- 大写字母 = 取第几个字（A=第1字，B=第2字，… Z=第26字）。
- 小写字母 = 该字编码的第几位（a=1码，b=2码，…）。
- `Z` = 最后一个字，`z` = 最后一码。
- 例（五笔 86 4 码词组）：
  - 二字词 `AaBaBbCc` → 各取前两码：`XxYy+ZzWw`。常用写法 `AaAbBaBb`
    （每字前两码）。
  - 三字词 `AaBaCa` → 前两字首码+第三字前两码。
  - 四字及以上 `AaBaCaZa` → 前三字首码+末字首码。
- `length_equal: 2` / `length_in_range: [3, 10]` 限定适用词长。
- `exclude_patterns`：正则排除（如不想为某类码造词）。
- **词库头没有 encoder/rules 则运行时造词静默失效**（本项目第 6 号坑）。
- 薄包装模式（本项目）：根包装 .dict.yaml 只写头部（import_tables + encoder），
  正文数据放子表。

## 5. preset vocabulary（八股文词频）

- `vocabulary: essay` + 编译时 `essay.txt`（官方预设 https://github.com/rime/essay ，
  在 shared data）注入词频；`min_phrase_weight` 过滤低频词组；`max_phrase_length` 限制注入词长。
- 本项目万象方案直接用带权重的词库，未走 essay。

## 6. 用户词典快照与调试

```bash
# tabledb（本项目当前形态）：直接看、直接改、直接 git
cd <用户目录>
tail -20 egret_wubi_py.user.dict.txt      # 格式: phrase<TAB>code<TAB>commits
# 清空机器自学习的两本（回归测试必做；custom_phrase 那本是人工内容，别删）
rm -f egret_wubi.user.dict.txt egret_wubi_py_script.user.dict.txt

# userdb（旧形态）的读法：
cd <用户目录>/build && strings egret_wubi.user.dict.userdb/*.ldb | head
rime_dict_manager --help                 # 快照/导入导出（工具在 build/bin/）
```

tabledb txt 格式（`table_db.cc::rime_table_entry_parser`）：`phrase<TAB>code<TAB>commits`；
commits 空则当 0。userdb 内键格式：`<text>\t<code>`（tabledb 落盘时 code 后**补一个空格**，
回读时靠它区分“精确匹配”），值为 `c=频次 d=最后使用日期 t=类型`。
以 `\x7fenc\x1f` 开头的 text 是自动造词条目（tabledb 里写作 `^?enc^_`）。

## 7. user_dict 共享陷阱 + “tabledb 只读”的更正（2026-10 实测）

- librime `UserDictionaryComponent::Create(dict_name, db_class)` 用 **db_pool_
  按 user_dict 名共享 db 实例**：多个 translator 的 `user_dict` 同名时，实际
  后端由**创建顺序**决定（先创建者胜出），后创建者的 db_class 被忽略。
- **更正**：`tabledb` **不是只读**。`tabledb` 走 `TextDb::Open()`（`readonly_=false`），
  `Update/Erase/MetaUpdate` 只在 `readonly()` 时拒写，`Close()` 还会 `SaveToFile()`。
  只读的是 `stabledb`（社区 custom_phrase 配方用它，这才是误会的源头）。
  2026-10 在本机 librime 1.17.0 上实测（`data/rime-test`）：
  混合库 tabledb 选第 3 候选（你好嘛）再打 → 升首位 ✓；传统库 tabledb 选第 2（徒增）
  → 升首位 ✓；传统库两段组句（trwu 我们 + gdrn 天气）回车 → 写出
  `我们天气\t^?enc^_qwgr\t0` 造词条目 ✓。跨进程、同进程都成立。
  2026-09-25 那条“选第 3 候选后再打次序不变”的观测**未能复现**，当时的根因登记有误。
- 真正的代价（2026-10 起仍选 tabledb，是权衡后的决定）：
  **同名共库时学习条目会直接写进人工维护的 custom phrase 文件**（实测被追加
  `你好嘛`、`好嘛`、`你`）；`Close()` 全量重写整张表；无事务/备份/损坏恢复；
  `rime_dict_manager` 快照工具按 userdb 布局工作。
  本项目因此给 translator 用**独立名**（`egret_wubi_py_script.user.dict`），
  手工短语库 `egret_wubi_py.user.dict` 保持干净。
- 副作用：名字不同 → db 实例不共享，script 组句**看不到**其它 translator 的学习条目。
  曾利用同名共享让 `ckwan` 出「台湾」（选台→选湾上屏后 script 能看到「湾 wan」）；
  分离后这条依赖消失（历史码造词仍走传统库自己的库）。

## 8. 跨词库造词学习限制（2026-09-25 实测）

- script translator 的 Memorize 对 CommitEntry 逐元素 UpdateEntry：
  元素的音节 id 属于**产生该候选的 prism**。混流句子「台(传统库 ck) + 湾(混合库
  wan)」中，台 的音节 id 是传统 prism 的，script 用户词典的音节表
  （混合 prism）无法翻译 → 台湾 整词学习失败，只有 湾(wan) 单字条目成功。
- 结论：跨 translator 组句的整词 user phrase 学习不可依赖；组合收益来自
  单字 user phrase 抬升组句，或词库层直接提供混合拼写词条（见 lm-grammar.md
  §6 同类问题修复）。

## 9. 本项目词库结构（现状速查）

```
egret_wubi_py.dict.yaml            # 混合库根（根目录；软链）→ import: 五笔字表+五笔词组+拼音字表+拼音词表
egret_wubi.dict.yaml       # 传统库根包装（手工维护）→ import: wubi_chars + wubi_words + user_phrases；含 encoder/rules
dicts/               # 生成数据（gen_wubi_py_unified_dicts.py 产出）
  egret_wubi_py_chars.dict.yaml    #   混合库五笔字表（ownership: 二级简码 owner 保留 ',' token）
  egret_wubi_chars.dict.yaml # 传统库字表（简码+全码，不过滤 2+2 冲突）
  egret_wubi_words_wb86_src.dict.yaml # 传统库词组
  egret_wubi_py_user_phrases.dict.yaml # 手工维护用户词组（tgtj 生不逢时 900）
  egret_py_chars.dict.yaml  # 拼音字表（无调化）
  egret_py_words_src.dict.yaml # 拼音词表（无调化）
dicts/wb86_wangxiang_cn_dicts/base.small.dict.yaml # 五笔词组（万象权重，>450 过滤）
```

改动任何词库/gen 脚本后：`python3 scripts/regression_test.py --rebuild`
（17 条黄金用例），见 `scripts/regression_test.py`。
