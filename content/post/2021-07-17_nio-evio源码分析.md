---
title: "NIO-evio源码分析"
date: 2021-07-17
lastmod: 2021-07-26
draft: false
tags: ["nio", "net", "golang", "evio"]

toc: true

---
## 开始之前
- evio是一个小巧的golang实现的NIO包，阅读源码的实现可以更好的帮助我们学习和了解NIO
- 由于使用mac，所以下面的分析主要以Kqueue为主，Epoll大同小异

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
使用时是比较方便的，只需要定义一个处理事件events，然后实现events定义的几个方法，然后启动serve即可。events后面再讲,让我们深入*evio.Serve*

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
        // 主要是用来判断addr，默认是tcp，支持udp，unix 还有一个特殊的 -net
        // 另外判断了一下 addr是否带有 ?reuseport=true，然后赋值给 ln.opts.reusePort 
        ln.network, ln.addr, ln.opts, stdlibt = parseAddr(addr)
        // 如果network是 -net，则使用stdlib
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
            // 获取socket的文件描述符，赋值给ln.fd，并设置为非阻塞
            if err := ln.system(); err != nil {
                return err
            }
        }
        lns = append(lns, &ln)
    }
    if stdlib {
        // 使用系统的netpoll，每个请求开一个线程去处理
        return stdserve(events, lns)
    }
    // 使用NIO的方式处理，kqueue/epoll
    return serve(events, lns)
}
```
可以看到Serve的大部分逻辑是对addr的处理，支持 tcp/unix/udp/-net，解析套接字fd然后放入一个lns的列表中，最后根据是否stdlib来分别调用stdserve和serve, 
因为我们主要关注nio，所以先来看下serve

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
        // 阻塞，等待关闭信号
        s.waitForShutdown()

        // notify all loops to close by closing all listeners
        // 准备关闭所有监听连接的文件描述符
        // 流程是先将 errClosing 放入 pool.noteQueue中，然后所有kq开始监听 NOTE_TRIGGER 事件 
        for _, l := range s.loops {
            l.poll.Trigger(errClosing)
        }

        // wait on all loops to complete reading events
        // 等待所有协程结束
        s.wg.Wait()

        // close loops and all outstanding connections
        for _, l := range s.loops {
            for _, c := range l.fdconns {
                // 关闭所有监听中的连接
                loopCloseConn(s, l, c, nil)
            }
            // 将自己关闭
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
        // 为每个listener创建changes事件列表，并添加read事件
        for _, ln := range listeners {
            l.poll.AddRead(ln.fd)
        }
        s.loops = append(s.loops, l)
    }
    // start loops in background
    // 用于协程等待
    s.wg.Add(len(s.loops))
    // 启动多个线程的监听
    for _, l := range s.loops {
        go loopRun(s, l)
    }
    return nil
}
```
serve方法主要是根据开启多个线程，每个线程初始化数据结构，包含 Kqueue/Epoll，读缓冲和连接的map，然后定义了关闭流程。可以看到处理线程loopRun
才是主要的连接处理

## loopRun
```go
func loopRun(s *server, l *loop) {
    defer func() {
        //fmt.Println("-- loop stopped --", l.idx)
        // 发送关闭信号给主线程
        s.signalShutdown()
        s.wg.Done()
    }()

    // 当线程的index为0并且events的tick不为nil， 则启动一个loopTicker线程，定时执行
    if l.idx == 0 && s.events.Tick != nil {
        /*
        loopTicker会定时触发自定义的note事件(添加note，触发kqueue/epoll
        func loopTicker(s *server, l *loop) {
            for {
                if err := l.poll.Trigger(time.Duration(0)); err != nil {
                    break
                }
                time.Sleep(<-s.tch)
            }
        }
         */
        go loopTicker(s, l)
    }

    //fmt.Println("-- loop started --", l.idx)
    // Wait是监听Kqueue/Epoll的主方法，接受一个func，用来进行文件描述符的操作
    // 这个func可以稍后再看，先看下面的Wait
    l.poll.Wait(func(fd int, note interface{}) error {
        // 可以看到当fd为0的时候，是一个note调用事件
        if fd == 0 {
            // 自定义事件
            return loopNote(s, l, note)
        }
        // 首先搜索此连接是否在自己的监听map中
        c := l.fdconns[fd]
        switch {
        // 如果没有，则调用accept方法，接受连接
        case c == nil:
            return loopAccept(s, l, fd)
        // 每个accept后的连接都必须调用一遍loopOpened
        case !c.opened:
            return loopOpened(s, l, c)
        // 如果连接的写缓冲有值，则调用写方法
        case len(c.out) > 0:
            return loopWrite(s, l, c)
        // 如果连接的动作不为空，则嗲用Action方法
        case c.action != None:
            return loopAction(s, l, c)
        // 默认调用读方法
        default:
            return loopRead(s, l, c)
        }
    })
}
```
loopRun方法主要是先处理events定义的Tick，然后是poll.Wait方法进行对Kqueue/Epoll和连接的处理，Wait接受一个func，是对fd的处理方法

## Wait
```go
func (p *Poll) Wait(iter func(fd int, note interface{}) error) error {
    // 创建events
    events := make([]syscall.Kevent_t, 128)
    for {
        // 这里就是Kqueue/Epoll的主方法，如果events有就绪的fd，则返回n表示有几个fd就绪
        n, err := syscall.Kevent(p.fd, p.changes, events, nil)
        // 当出现EINTR的时候表示内核错误，程序终止
        if err != nil && err != syscall.EINTR {
            return err
        }
        // 这里会把changes清空，因为只需要注册一遍就可以了
        p.changes = p.changes[:0]
        // 这里会先进行notes的执行 
        if err := p.notes.ForEach(func(note interface{}) error {
            // 具体的iter就是上面传入的方法，可以返回上面继续看
            return iter(0, note)
        }); err != nil {
            return err
        }
        // 然后才是遍历events，调用iter
        for i := 0; i < n; i++ {
            if fd := int(events[i].Ident); fd != 0 {
                if err := iter(fd, nil); err != nil {
                    return err
                }
            }
        }
    }
}
```
可以看到，Wait的处理很清晰，就是等待内核通知events就绪，然后在处理fd之前，先把note处理一遍，再遍历处理fd，具体的处理方法分别定义在了iter中
## 处理方法
总共有6中处理方法
### loopNote
先来看看loopNote
```go
func loopNote(s *server, l *loop, note interface{}) error {
    var err error
    switch v := note.(type) {
    // 如果note的类型是时间类型，则根据events.Tick进行调用，之前index=0线程启动的时候也是有个判断，如果Tick不为nil，则会启动一个
    // loopTicker线程，往note里面推送事件，并发送kqueue/epoll自定义事件触发就绪，然后会到这里进行Tick的实际调用
    case time.Duration:
        delay, action := s.events.Tick()
        switch action {
        case None:
        case Shutdown:
            err = errClosing
        }
        s.tch <- delay
    case error: // shutdown
        err = v
    // 如果是一个连接
    case *conn:
        // Wake called for connection
        if l.fdconns[v.fd] != v {
            return nil // ignore stale wakes
        }
        /*
            func loopWake(s *server, l *loop, c *conn) error {
                if s.events.Data == nil {
                    return nil
                }
                out, action := s.events.Data(c, nil)
                c.action = action
                if len(out) > 0 {
                    c.out = append([]byte{}, out...)
                }
                if len(c.out) != 0 || c.action != None {
                    l.poll.ModReadWrite(c.fd)
                }
                return nil
            }
        */
        // loopWake主要是对连接进行Data调用 
        return loopWake(s, l, v)
    }
    return err
}
```
可以看到loopNote主要是对自定义事件的处理，自定义事件包括3种类型：定时任务，错误，连接

### loopAccept
```go
func loopAccept(s *server, l *loop, fd int) error {
    // 首先根据fd找到监听fd，然后根据负载均衡策略找到指定哪个loop线程进行accept
    for i, ln := range s.lns {
        if ln.fd == fd {
            if len(s.loops) > 1 {
                switch s.balance {
                case LeastConnections:
                    n := atomic.LoadInt32(&l.count)
                    for _, lp := range s.loops {
                        if lp.idx != l.idx {
                            if atomic.LoadInt32(&lp.count) < n {
                                return nil // do not accept
                            }
                        }
                    }
                case RoundRobin:
                    idx := int(atomic.LoadUintptr(&s.accepted)) % len(s.loops)
                    if idx != l.idx {
                        return nil // do not accept
                    }
                    atomic.AddUintptr(&s.accepted, 1)
                }
            }
            if ln.pconn != nil {
                return loopUDPRead(s, l, i, fd)
            }
            // 系统调用Accept
            nfd, sa, err := syscall.Accept(fd)
            if err != nil {
                // 如果是EAGAIN表示未就绪，需要重新获取，所以返回nil
                if err == syscall.EAGAIN {
                    return nil
                }
                return err
            }
            // 需要设置为非阻塞
            if err := syscall.SetNonblock(nfd, true); err != nil {
                return err
            }
            // 创建连接的数据结构
            c := &conn{fd: nfd, sa: sa, lnidx: i, loop: l}
            c.out = nil
            l.fdconns[c.fd] = c
            // 添加读写监听
            l.poll.AddReadWrite(c.fd)
            atomic.AddInt32(&l.count, 1)
            break
        }
    }
    return nil
}
```
loopAccept主要是accept连接，并将nfd设置为非阻塞，然后根据负载均衡将nfd注册到对应的kqueue/epoll中，监听其读写
### loopOpened
loopOpened是每个连接建立之后，需要进行的第一步
```go
func loopOpened(s *server, l *loop, c *conn) error {
    // 设置为open，表示已经运行过open，后面就不会再运行了
    c.opened = true
    c.addrIndex = c.lnidx
    c.localAddr = s.lns[c.lnidx].lnaddr
    c.remoteAddr = internal.SockaddrToAddr(c.sa)
    // 如果定义了Opened方法，则执行Opened方法
    if s.events.Opened != nil {
        out, opts, action := s.events.Opened(c)
        if len(out) > 0 {
            c.out = append([]byte{}, out...)
        }
        c.action = action
        c.reuse = opts.ReuseInputBuffer
        // 设置TCP长连接
        if opts.TCPKeepAlive > 0 {
            if _, ok := s.lns[c.lnidx].ln.(*net.TCPListener); ok {
                internal.SetKeepAlive(c.fd, int(opts.TCPKeepAlive/time.Second))
            }
        }
    }
    // 如果是默认的没有执行Opened的连接，则首先读（删除写事件）
    if len(c.out) == 0 && c.action == None {
        l.poll.ModRead(c.fd)
    }
    return nil
}
```
loopOpened是每个新连接都会调用一遍的方法，如果定义了events.Opened， 则会调用定义的Opened方法，并根据返回的opt进行一些连接的额外操作，目前
只有`TCPKeepAlive长连接`和`ReuseInputBuffer复用buffer`两个可选参数
### loopWrite
loopWrite主要是写事件
```go
func loopWrite(s *server, l *loop, c *conn) error {
    // 如果定义了PreWrite，则调用
    if s.events.PreWrite != nil {
        s.events.PreWrite()
    }
    // 系统调用Write方法
    n, err := syscall.Write(c.fd, c.out)
    if err != nil {
        // EAGAIN表示未就绪
        if err == syscall.EAGAIN {
            return nil
        }
        // 其他错误直接关闭连接，并调用events定义的Closed方法
        return loopCloseConn(s, l, c, err)
    }
    // c.out全部写入到系统缓冲
    if n == len(c.out) {
        // release the connection output page if it goes over page size,
        // otherwise keep reusing existing page.
        // 如果c.out > 4096 则释放缓冲，否则复用
        if cap(c.out) > 4096 {
            c.out = nil
        } else {
            c.out = c.out[:0]
        }
    } else {
        // 如果c.out没有全部写入缓冲（当缓冲区满时），则保留未写入的
        c.out = c.out[n:]
    }
    // 如果已经写完数据了，则将监听模式转为读模式（删除写监听）
    if len(c.out) == 0 && c.action == None {
        l.poll.ModRead(c.fd)
    }
    return nil
}
```
写方法主要是当写缓冲（c.out）中存在数据时进行调用。当内核写缓冲不足，只写了一部分之后，保留剩下的部分，继续进入循环
### loopAction
action主要是对一个定义的行为进行操作
```go
func loopAction(s *server, l *loop, c *conn) error {
    switch c.action {
    default:
        c.action = None
    // 关闭连接
    case Close:
        return loopCloseConn(s, l, c, nil)
    // 关闭服务
    case Shutdown:
        return errClosing
    // 分离连接，events的Detached必须定义，分离后的连接不再被管理，并由events.Detached调用后处理
    case Detach:
        return loopDetachConn(s, l, c, nil)
    }
    // 默认读模式
    if len(c.out) == 0 && c.action == None {
        l.poll.ModRead(c.fd)
    }
    return nil
}
```
action主要是定义了三个操作：关闭连接，关闭服务，分离连接（类似net/http的hijack）
### loopRead
默认的读操作
```go
func loopRead(s *server, l *loop, c *conn) error {
    var in []byte
    // packet是读缓冲，在loop创建时定义的，大小为0xFFFF
    n, err := syscall.Read(c.fd, l.packet)
    if n == 0 || err != nil {
        // 如果内核返回EAGAIN，则直接返回，等待下次调用
        if err == syscall.EAGAIN {
            return nil
        }
        // 其他错误关闭连接
        return loopCloseConn(s, l, c, err)
    }
    // 读完后赋值给in, 这样就腾出来packet给其他连接使用了，由于是每个loop是单线程，所以不存在锁的问题
    in = l.packet[:n]
    // 如果不复用，则会拷贝一份数据到新的内存地址，这里主要考虑到in和packet共享了同一块内存数据，如果有修改会互相影响
    if !c.reuse {
        in = append([]byte{}, in...)
    }
    // 如果Data不为空，则调用Data，Data属于主要的处理方法
    if s.events.Data != nil {
        out, action := s.events.Data(c, in)
        c.action = action
        // 如果有输出则保存输出，这里也是重新申请了内存，然后将out的数据复制过去
        if len(out) > 0 {
            c.out = append(c.out[:0], out...)
        }
    }
    // 如果存在out数据，则注册写事件，后面写就绪后会触发写事件
    if len(c.out) != 0 || c.action != None {
        l.poll.ModReadWrite(c.fd)
    }
    return nil
}
```
读方法主要是对数据的读取，然后调用Data方法，所以具体的逻辑处理都是在Data中进行的。比如说读取的数据不完整，需要在Data中做记录，然后继续等待
数据填充结束，类似http协议中的`content-length`

## EVENTS
evio定义了一个events数据结构，他有几个参数是用来做一些逻辑处理的
- Serving 当服务启动的时候会调用一次
- Opened 当新连接建立后会调用一次
- Closed 当连接关闭时调用
- Detach 当收到action为Detach时调用
- Data 当从连接中读取到数据时调用
- Tick 服务启动的时候调用一次，后面会定时调用

## 总结
evio的整体架构还是比较清晰的，外层通过events的几个方法编写逻辑，进行数据处理；内层通过 Kqueue/Epoll 事件驱动的形式进行数据读写，同时通过
events返回的action可以通知内层逻辑处理。


