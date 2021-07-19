---
title: "NIO-evio源码分析WIP"
date: 2021-07-17
lastmod: 2021-07-17
draft: false
tags: ["nio", "net", "golang", "evio"]

toc: true

---
## 开始之前
evio是一个小巧的golang实现的NIO包, 阅读源码的实现可以更好的帮助我们学习和了解NIO

[源码地址](https://github.com/tidwall/evio)

## 简单的echo服务
下面是一个官方的简单echo服务例子
```go
package main

import "github.com/tidwall/evio"

func main() {
    // 定义事件处理方法
    var events evio.Events
    events.Data = func(c evio.Conn, in []byte) (out []byte, action evio.Action) {
        out = in
        return
    }
    // 主循环入口
    if err := evio.Serve(events, "tcp://localhost:5000"); err != nil {
        panic(err.Error())
    }
}
```
使用时是比较方便的, 只需要定义一个处理events, 然后实现events定义的几个方法, 然后启动主循环即可. events后面再讲,让我们深入*evio.Serve*中

## 主入口 evio.Serve
```go
// 可以支持同时开启多个网络监听
func Serve(events Events, addr ...string) error {
    var lns []*listener
    defer func() {
        for _, ln := range lns {
            ln.close()
        }
    }()
    var stdlib bool
    for _, addr := range addr {
        var ln listener
        var stdlibt bool
        // 主要是用来判断addr, 默认是tcp, 支持udp, unix 还有一个特殊的 -net
        // 另外判断了一下 addr是否带有 ?reuseport=true, 然后赋值给 ln.opts.reusePort 
        ln.network, ln.addr, ln.opts, stdlibt = parseAddr(addr)
        // 如果network是 -net, 则使用stdlib
        // stdlib 指使用
        if stdlibt {
            stdlib = true
        }
        // 创建网络监听的sockets
        if ln.network == "unix" {
            os.RemoveAll(ln.addr)
        }
        var err error
        if ln.network == "udp" {
            if ln.opts.reusePort {
                ln.pconn, err = reuseportListenPacket(ln.network, ln.addr)
            } else {
                ln.pconn, err = net.ListenPacket(ln.network, ln.addr)
            }
        } else {
            if ln.opts.reusePort {
                ln.ln, err = reuseportListen(ln.network, ln.addr)
            } else {
                ln.ln, err = net.Listen(ln.network, ln.addr)
            }
        }
        if err != nil {
            return err
        }
        if ln.pconn != nil {
            ln.lnaddr = ln.pconn.LocalAddr()
        } else {
            ln.lnaddr = ln.ln.Addr()
        }
        if !stdlib {
            // 获取socket的文件描述符, 赋值给ln.fd, 并设置为非阻塞
            if err := ln.system(); err != nil {
                return err
            }
        }
        lns = append(lns, &ln)
    }
    if stdlib {
        // 使用系统的netpoll, 每个请求开一个线程去处理
        return stdserve(events, lns)
    }
    // 使用NIO的方式处理, kqueue/epoll
    return serve(events, lns)
}
```
主入口主要是对addr做处理, 支持 tcp/unix/udp/-net, 解析套接字fd然后放入一个lns的列表中, 最后根据是否stdlib来分别调用stdserve和serve, 
因为我们主要关注nio, 所以先来看下serve

## 处理方法 serve
```go
func serve(events Events, listeners []*listener) error {
    // figure out the correct number of loops/goroutines to use.
	// 设定监听线程数
    numLoops := events.NumLoops
    if numLoops <= 0 {
        if numLoops == 0 {
            numLoops = 1
        } else {
            numLoops = runtime.NumCPU()
        }
    }

    s := &server{}
    s.events = events
    s.lns = listeners
    s.cond = sync.NewCond(&sync.Mutex{})
    // 负载均衡 Random随机/RoundRobin轮训/LeastConnections最小连接
    s.balance = events.LoadBalance
    s.tch = make(chan time.Duration)

    //println("-- server starting")
    // 当准备accept新连接时运行events的Serving方法，具体看后面events的分析
    if s.events.Serving != nil {
        var svr Server
        svr.NumLoops = numLoops
        svr.Addrs = make([]net.Addr, len(listeners))
        for i, ln := range listeners {
            svr.Addrs[i] = ln.lnaddr
        }
        action := s.events.Serving(svr)
        switch action {
        case None:
        case Shutdown:
            return nil
        }
    }

    defer func() {
        // wait on a signal for shutdown
        s.waitForShutdown()

        // notify all loops to close by closing all listeners
        for _, l := range s.loops {
            l.poll.Trigger(errClosing)
        }

        // wait on all loops to complete reading events
        s.wg.Wait()

        // close loops and all outstanding connections
        for _, l := range s.loops {
            for _, c := range l.fdconns {
                loopCloseConn(s, l, c, nil)
            }
            l.poll.Close()
        }
        //println("-- server stopped")
    }()

    // create loops locally and bind the listeners.
    for i := 0; i < numLoops; i++ {
        l := &loop{
            idx:     i,
            poll:    internal.OpenPoll(),  // 创建Kqueue/epoll
            packet:  make([]byte, 0xFFFF), // 读缓冲
            fdconns: make(map[int]*conn),  // 连接管理的map
        }
        // 添加read事件到Kqueue/epoll的changes列表，这里并没有调用方法，只是append到了列表中
        for _, ln := range listeners {
            l.poll.AddRead(ln.fd)
        }
        s.loops = append(s.loops, l)
    }
    // start loops in background
    s.wg.Add(len(s.loops))
    // 启动多个线程的监听
    for _, l := range s.loops {
        go loopRun(s, l)
    }
    return nil
}
```



