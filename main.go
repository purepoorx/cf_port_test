package main

import (
	"fmt"
	"net/http"
)

func main() {
	// 设置路由规则
	http.HandleFunc("/", dynamicHandler)

	// 启动Web服务，监听8888端口
	err := http.ListenAndServe(":8888", nil)
	if err != nil {
		fmt.Println("Error starting server:", err)
	}
}

// 处理请求的函数
func dynamicHandler(w http.ResponseWriter, r *http.Request) {
	// 获取请求路径
	path := r.URL.Path

	//// 根据不同的路径返回不同的响应
	//switch path {
	//case "/hello":
	//	fmt.Fprint(w, "hello")
	//case "/welcome":
	//	fmt.Fprint(w, "welcome")
	//default:
	//	fmt.Fprint(w, "unknown path")
	//}

	// 使用切片去除第一个字符
	if len(path) > 1 {
		path = path[1:]
	} else {
		path = ""
	}

	fmt.Fprint(w, path)
}
