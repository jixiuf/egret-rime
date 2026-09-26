package main

import (
	"fmt"
	"path/filepath"
	"runtime"
	"scripts/rime"
)

// repoRoot 返回仓库根目录(scripts/ 的上一级), 不依赖当前工作目录。
func repoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(file))
}

// dictsPath 拼接仓库内 dicts/ 下的路径(参数为逐级目录/文件名)。
func dictsPath(parts ...string) string {
	return filepath.Join(append([]string{repoRoot(), "dicts"}, parts...)...)
}

func main() {
	// wubi86CharDict := loadWubiChars()
}
func loadWubiChars() (wubi86CharDict *rime.Dict) {
	wubi86CharDict, err := rime.ParseDict(dictsPath("wubi86", "wubi86.chars.dict.yaml"))
	if err != nil {
		fmt.Println("Error parsing dictionary:", err)
		return
	}
	return
}

// 提取wubi 单字
func saveWubiChar() {
	wubi86, err := rime.ParseDict(dictsPath("wubi86", "wubi86.dict.yaml"))
	if err != nil {
		fmt.Println("Error parsing dictionary:", err)
		return
	}
	destDict := rime.NewDictFrom("wubi86.chars", wubi86)
	for _, e := range wubi86.Entries {
		if len(e.Chars()) != 1 {
			continue
		}
		destDict.Entries.Add(e.Clone())
	}
	destDict.Write(dictsPath("wubi86", "wubi86.chars.dict.yaml"))

}
func loadWubi() {
	wubi86, err := rime.ParseDict(dictsPath("wubi86", "wubi86.dict.yaml"))
	if err != nil {
		fmt.Println("Error parsing dictionary:", err)
		return
	}
	wubi, err := rime.ParseDict(dictsPath("wubi86", "wubi.dict.yaml"))
	if err != nil {
		fmt.Println("Error parsing dictionary:", err)
		return
	}
	for _, entry := range wubi.Entries {
		if len(entry.Chars()) != 1 {
			continue
		}
		if wubi86.Entries.ContainsAll(entry.Word) {
			continue
		}

		appended := wubi86.Entries.Add(entry.Clone())
		if appended > 0 {
			fmt.Println(entry.Word, entry.Code, entry.Weight)
		}

	}

}
