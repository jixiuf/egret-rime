package main

import (
	"fmt"
	"path/filepath"
	"runtime"
	"scripts/rime"
)

// 结合 无声调版的 (白霜字库8105.dict.yaml) 与有声调版的 万象拼音大 “字”库
// 筛选出有声调版的 8105.dict.yaml
func main() {

	// 无声调版的 (白霜字库)
	dict8105NoTone, err := rime.ParseDict(dictsPath("frost_cn_dicts", "8105.dict.yaml"))
	if err != nil {
		fmt.Println("Error parsing dictionary:", err)
		return
	}
	// 有声调版的 万象拼音大 “字”库
	charsDictTone, err := rime.ParseDict(dictsPath("wangxiang_cn_dicts", "chars.dict.yaml"))
	if err != nil {
		fmt.Println("Error parsing dictionary:", err)
		return
	}
	dict8105Tone := rime.NewDict("8105")
	dict8105Tone.FileComments = `
# 本字库使用 generate_8105_pinyin_tone.go 生成
# 结合 无声调版的 (白霜字库8105.dict.yaml) 与有声调版的 万象拼音大 “字”库(chars.dict.yaml)
# 筛选出有声调版的 本字库 8105.dict.yaml
`
	for _, entry := range charsDictTone.Entries {
		e := entry.RemoveTone()
		es := dict8105NoTone.Entries.FindByWordAndCode(e.Word, e.Code)
		if len(es) > 0 {
			dict8105Tone.Entries.Add(entry.Clone())
		}
	}

	// dict.SortByWeight() // 按权重排序

	// 写回文件
	err = dict8105Tone.Write(dictsPath("wangxiang_cn_dicts", "8105.dict.yaml"))
	if err != nil {
		fmt.Println("Error serializing dictionary:", err)
		return
	}

}

// repoRoot 返回仓库根目录(scripts/ 的上一级), 不依赖当前工作目录。
func repoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(file))
}

// dictsPath 拼接仓库内 dicts/ 下的路径(参数为逐级目录/文件名)。
func dictsPath(parts ...string) string {
	return filepath.Join(append([]string{repoRoot(), "dicts"}, parts...)...)
}
