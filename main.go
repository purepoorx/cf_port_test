package main

import (
	"fmt"
	"net/http"
	"sync"
)

var mux = http.NewServeMux()
var mu sync.Mutex

func handler(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()

	// 获取请求的端口号
	port := r.URL.Port()

	// 如果端口号为空，默认使用80
	if port == "" {
		port = "80"
	}

	// 构造响应消息
	//message := fmt.Sprintf("当前请求的端口是：%s", port)

	// 将消息写入响应
	w.Write([]byte(port))
}

func main() {
	// 遍历指定的端口列表
	ports := []string{"80", "8080", "8880", "2052", "2082", "2086", "2095", "443", "2053", "2083", "2087", "2096", "8443"}

	for _, port := range ports {
		go func(p string) {
			// 设置路由处理函数
			mux.HandleFunc("/", handler)

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
