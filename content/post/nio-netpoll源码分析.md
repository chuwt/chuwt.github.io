---
title: "NIO-evio源码分析"
date: 2021-07-26
lastmod: 2021-07-26
draft: false
tags: ["nio", "net", "golang", "netpoll"]

toc: true

---
## 开始之前
- 上一篇我们讲了一个evio，这节我们来看一看字节跳动开源的高性能nio库，netpoll

[源码地址](https://github.com/cloudwego/netpoll)