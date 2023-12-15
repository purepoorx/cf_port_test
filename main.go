package main

import (
	"fmt"
	"net/http"
	"sync"
)

var mu sync.Mutex

func handler(w http.ResponseWriter, r *http.Request, port string) {
	mu.Lock()
	defer mu.Unlock()

	// 构造响应消息
	message := fmt.Sprintf("当前请求的端口是：%s", port)

	// 将消息写入响应
	w.Write([]byte(message))
}

func main() {
	// 遍历指定的端口列表
	ports := []string{"80", "8080", "8880", "2052", "2082", "2086", "2095", "443", "2053", "2083", "2087", "2096", "8443"}

	// 启动一个 goroutine 处理一个端口
	for _, port := range ports {
		go func(p string) {
			// 创建每个端口的 ServeMux
			mux := http.NewServeMux()

			// 注册路由处理函数
			mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
				handler(w, r, p)
			})

			// 启动Web服务监听指定端口
			err := http.ListenAndServe(":"+p, mux)
			if err != nil {
				fmt.Printf("启动Web服务失败：%v\n", err)
			}
		}(port)
	}

	// 阻止主函数退出，以保持服务一直运行
	select {}
}
