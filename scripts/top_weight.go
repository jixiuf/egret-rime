package main

import (
	"fmt"
	"path/filepath"
	"runtime"
	"scripts/rime"
	"strings"
)

// 只保留源dict中权重大于 minWeight 的词条

// repoRoot 返回仓库根目录(scripts/ 的上一级), 不依赖当前工作目录。
func repoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(file))
}

// dictsPath 拼接仓库内 dicts/ 下的路径(参数为逐级目录/文件名)。
func dictsPath(parts ...string) string {
	return filepath.Join(append([]string{repoRoot(), "dicts"}, parts...)...)
}

var dicts = map[string]float64{ // value=min_weight
	dictsPath("wangxiang_cn_dicts", "base.dict.yaml"):        450,
	dictsPath("wangxiang_cn_dicts", "correlation.dict.yaml"): 300,
	dictsPath("wb86_cn_dicts", "base.dict.yaml"):             300,
	dictsPath("wb86_cn_dicts", "ext.dict.yaml"):              30,
	// dictsPath("wubi86", "wubi86.dict.yaml"):      0,
	// dictsPath("wubi86", "wubi86.base.dict.yaml"): 0,
}

func main() {
	for dict, minWeight := range dicts {
		dir := filepath.Dir(dict)
		dictFileName := filepath.Base(dict)
		dictName := strings.TrimSuffix(dictFileName, ".dict.yaml") + ".small"
		outputFileName := filepath.Join(dir, fmt.Sprintf("%s.dict.yaml", dictName))

		// 有声调版的 万象拼音大 “字”库
		baseDict, err := rime.ParseDict(dict)
		if err != nil {
			fmt.Println("Error parsing dictionary:", err)
			return
		}
		dictOutput := rime.NewDict(dictName)
		dictOutput.FileComments = fmt.Sprintf(`
# 本字库使用 top_weight.go 生成
#只保留权重>%.0f 的
%s`, minWeight, baseDict.FileComments)
		baseDict.Entries.SortByWeight() // 按权重排序
		for _, e := range baseDict.Entries {
			if e.Weight >= minWeight {
				dictOutput.Entries = append(dictOutput.Entries, e)
			}
		}

		// 写回文件
		err = dictOutput.Write(outputFileName)
		if err != nil {
			fmt.Println("Error serializing dictionary:", err)
			return
		}

	}

}
