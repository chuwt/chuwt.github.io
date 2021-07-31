---
title: "NIO-netpoll源码分析"
date: 2021-07-26
lastmod: 2021-07-26
draft: false
tags: ["nio", "golang", "zero-copy"]

toc: true

---
## 开始之前
- 上一篇我们讲了一个evio，这节我们来看一看字节跳动开源的高性能nio库，netpoll
- 由于使用mac，所以下面的分析主要以Kqueue为主，Epoll大同小异

[源码地址](https://github.com/cloudwego/netpoll)

## 示例
先上一个官方示例看一看使用方法
```go
package main

import (
    "context"
    "time"
    "github.com/cloudwego/netpoll"
)

func main() {
    network, address := "tcp", "127.0.0.1:8888"
    
    // 创建 listener
    listener, err := netpoll.CreateListener(network, address)
    if err != nil {
        panic("create netpoll listener fail")
    }
    
    // handle: 连接读数据和处理逻辑
    var onRequest netpoll.OnRequest = handler
    
    // options: EventLoop 初始化自定义配置项
    var opts = []netpoll.Option{
        netpoll.WithReadTimeout(1 * time.Second),
        netpoll.WithIdleTimeout(10 * time.Minute),
        netpoll.WithOnPrepare(nil),
    }
    
    // 创建 EventLoop
    eventLoop, err := netpoll.NewEventLoop(onRequest, opts...)
    if err != nil {
        panic("create netpoll event-loop fail")
    }
    
    // 运行 Server
    err = eventLoop.Serve(listener)
    if err != nil {
        panic("netpoll server exit")
    }
}

// 读事件处理
func handler(ctx context.Context, connection netpoll.Connection) error {
    return connection.Writer().Flush()
}
```
使用逻辑还是很清晰的：
1. 创建listener
2. 编写处理handler
3. 创建eventLoop
4. 启动eventLoop

## 创建listener
首先看下创建listener的逻辑
```go
// CreateListener return a new Listener.
func CreateListener(network, addr string) (l Listener, err error) {
    ln := &listener{
        network: network,
        addr:    addr,
    }

    defer func() {
        if err != nil {
            ln.Close()
        }
    }()

    // 创建udp的listener，并且获取fd
    if ln.network == "udp" {
        // TODO: udp listener.
        ln.pconn, err = net.ListenPacket(ln.network, ln.addr)
        if err != nil {
            return nil, err
        }
        ln.lnaddr = ln.pconn.LocalAddr()
        switch pconn := ln.pconn.(type) {
        case *net.UDPConn:
            ln.file, err = pconn.File()
        }
    } else {
        // 获取 tcp, tcp4, tcp6, unix 的fd
        ln.ln, err = net.Listen(ln.network, ln.addr)
        if err != nil {
            return nil, err
        }
        ln.lnaddr = ln.ln.Addr()
        switch netln := ln.ln.(type) {
        case *net.TCPListener:
            ln.file, err = netln.File()
        case *net.UnixListener:
            ln.file, err = netln.File()
        }
    }
    if err != nil {
        return nil, err
    }
    ln.fd = int(ln.file.Fd())
    // 设置为非阻塞
    return ln, syscall.SetNonblock(ln.fd, true)
}
```
CreateListener的目的主要是获取listener的fd，并设置为非阻塞

## 创建eventLoop
暂时先不理会handler，看一看eventLoop的创建
```go
func NewEventLoop(onRequest OnRequest, ops ...Option) (EventLoop, error) {
    /* 接收配置
     目前可用的配置主要有三个
     1. onPrepare   连接初始化之前的准备操作，比如qps limiter
     2. readTimeout 读超时
     3. idleTimeout 空闲超时
     */
    opt := &options{}
    for _, do := range ops {
        do.f(opt)
    }
    // EventLoop是一个interface
    // eventLoop是一个实现了EventLoop接口的结构体
    return &eventLoop{
        opt:     opt,                    // 上面的opt
        prepare: opt.prepare(onRequest), // 装饰器，每个连接进来后都会调用此方法
        stop:    make(chan error, 1),    // 服务停止
    }, nil
}
```
NewEventLoop主要是初始化eventLoop的配置，主要有
1. onPrepare   连接初始化之前的准备操作，比如qps limiter
2. readTimeout 读超时
3. idleTimeout 空闲超时

## eventLoop.Serve
最后的入口是Serve，让我们看看Serve的逻辑
```go
type eventLoop struct {
    sync.Mutex
    opt     *options
    prepare OnPrepare
    svr     *server
    stop    chan error
}

func (evl *eventLoop) Serve(ln Listener) error {
    evl.Lock()
    // 生成server
    /*
    func newServer(ln Listener, prepare OnPrepare, quit func(err error)) *server {
        return &server{
            ln:      ln,
            prepare: prepare,
            quit:    quit,
        }
    }
     */
    evl.svr = newServer(ln, evl.prepare, evl.quit)
    // 启动server
    // Run方法是主要的启动方法
    evl.svr.Run()
    evl.Unlock()
    // 等待server退出
    /*
    func (evl *eventLoop) waitQuit() error {
        return <-evl.stop
    }
     */
    return evl.waitQuit()
}
```
Serve包括三个流程
1. 创建server对象
2. 调用server.Run
3. 等待server退出

## server.Run
看一看server运行的逻辑
```go
// Run this server.
func (s *server) Run() (err error) {
    // 新建一个FDOperator对象
    s.operator = FDOperator{
        FD:     s.ln.Fd(), // socket的FD
        OnRead: s.OnRead,  // Read方法，主要是Accept接受连接，后面进行分析
        /*
        func (s *server) OnHup(p Poll) error {
            s.quit(errors.New("listener close"))
            return nil
        }
        OnHup则直接调用quit关闭server
         */
        OnHup:  s.OnHup, 
    }
    // 这里的 pollmanager 是通过init方法进行初始化的，后面进行分析
    // Pick是根据负载均衡获取一个poll
    s.operator.poll = pollmanager.Pick()
    // Control则调用 poll.Control 
    err = s.operator.Control(PollReadable)
    if err != nil {
        s.quit(err)
    }
    return err
}
```
Run方法首先创建了一个operator对象，然后通过pollmanager获取一个poll，然后调用poll的Control方法。接下来我们看一看pollmanager是哪里来的，
poll又是如何创建的
## pollmanager
```go
// poll_manager.go

func init() {
    // 根据cpu数量判断线程数
    var loops = runtime.GOMAXPROCS(0)/20 + 1
    /*
    type manager struct {
        NumLoops int
        balance  loadbalance // load balancing method
        polls    []Poll      // all the polls
    }
     */
    pollmanager = &manager{}
    // 获取一个负载均衡对象，然后赋值给balance，目前只支持：RoundRobin轮训，Random随机
    pollmanager.SetLoadBalance(RoundRobin)
    // 设置线程循环，具体看下面的方法 
    pollmanager.SetNumLoops(loops)
}

// SetNumLoops will return error when set numLoops < 1
func (m *manager) SetNumLoops(numLoops int) error {
    if numLoops < 1 {
        return fmt.Errorf("set invaild numLoops[%d]", numLoops)
    }
    // if less than, reset all; else new the delta.
    if numLoops < m.NumLoops {
        m.NumLoops = numLoops
        /*
        func (m *manager) Reset() error {
            for _, poll := range m.polls {
                poll.Close()
            }
            m.polls = nil
            return m.Run()
        }
        关闭所有已经存在的poll，然后重新调用Run方法
         */
        return m.Reset()
    }
    m.NumLoops = numLoops
    // 启动循环线程，具体看下面的方法
    return m.Run()
}

// Run all pollers.
func (m *manager) Run() error {
    // new poll to fill delta.
    // 创建NumLoops个poll，然后调用pool.Wait方法
    for idx := len(m.polls); idx < m.NumLoops; idx++ {
        /*
        下面是一个Kqueue的poll
        
        func openDefaultPoll() *defaultPoll {
            l := new(defaultPoll)
            p, err := syscall.Kqueue()
            if err != nil {
                panic(err)
            }
            l.fd = p
            _, err = syscall.Kevent(l.fd, []syscall.Kevent_t{{
                Ident:  0,
                Filter: syscall.EVFILT_USER,
                Flags:  syscall.EV_ADD | syscall.EV_CLEAR,
            }}, nil, nil)
            if err != nil {
                panic(err)
            }
            return l
        }
         */
        // 默认注册了一个用户自定义事件
        var poll = openPoll()
        m.polls = append(m.polls, poll)
        // 启动一个协程运行Wait方法，里面就是对已经存在的连接的处理逻辑，后面进行分析，首先先看一下连接是如何初始化的
        go poll.Wait()
    }
    // LoadBalance must be set before calling Run, otherwise it will panic.
    /*
    func (b *roundRobinLB) Rebalance(polls []Poll) {
        b.polls, b.pollSize = polls, len(polls)
    }
     */
    // Rebalance 则把balance的polls和pollSize进行重新赋值
    m.balance.Rebalance(m.polls)
    return nil
}
```
可以看到pollmanager是在程序启动时初始化的，主要包含若干个poll，Pick时通过负载均衡返回poll，目前有 轮训/随机 两种方式。
同时每个poll会开一个线程进行poll的事件监听，暂时先把处理逻辑放下，看一看连接是怎么放入poll中的

## Control
让我们回到server.Run里，看一看Control的逻辑
```go
// Control直接调用了poll的Control逻辑
func (op *FDOperator) Control(event PollEvent) error {
    return op.poll.Control(op, event)
}

// Control implements Poll.
func (p *defaultPoll) Control(operator *FDOperator, event PollEvent) error {
    var evs = make([]syscall.Kevent_t, 1)
    // 设置Ident为文件描述符
    evs[0].Ident = uint64(operator.FD)
    // Udata是自定义数据，是一个*byte
    // 这里的Udata存储的是*FDOperator，所以获取Udata的指针是一个(**FDOperator)的类型，然后获取其值则是*(**FDOperator)
    *(**FDOperator)(unsafe.Pointer(&evs[0].Udata)) = operator
    // 定义的事件
    /*
    PollReadable PollEvent = 0x1        // 读
    PollWritable PollEvent = 0x2        // 写
    PollDetach PollEvent = 0x3          // 分离
    PollModReadable PollEvent = 0x4     // 重新注册的读
    PollR2RW PollEvent = 0x5            // 读变读写
    PollRW2R PollEvent = 0x6            // 读写变读
     */
    switch event {
    case PollReadable, PollModReadable:
        // 设置标记位为使用中
        /*
        func (op *FDOperator) inuse() {
            for !atomic.CompareAndSwapInt32(&op.state, 0, 1) {
                if atomic.LoadInt32(&op.state) == 1 {
                    return
                }
                // 这里会一直等待设置成功，不成功则暂时挂起，防止for循环一直占用CPU资源
                runtime.Gosched()
            }
        }
         */
        operator.inuse()
        evs[0].Filter, evs[0].Flags = syscall.EVFILT_READ, syscall.EV_ADD|syscall.EV_ENABLE
    case PollDetach:
        // 和inuse差不多，只是在Kevent触发之后进行操作
        defer operator.unused()
        evs[0].Filter, evs[0].Flags = syscall.EVFILT_READ, syscall.EV_DELETE|syscall.EV_ONESHOT
    case PollWritable:
        operator.inuse()
        evs[0].Filter, evs[0].Flags = syscall.EVFILT_WRITE, syscall.EV_ADD|syscall.EV_ENABLE|syscall.EV_ONESHOT
    case PollR2RW:
        evs[0].Filter, evs[0].Flags = syscall.EVFILT_WRITE, syscall.EV_ADD|syscall.EV_ENABLE
    case PollRW2R:
        evs[0].Filter, evs[0].Flags = syscall.EVFILT_WRITE, syscall.EV_DELETE|syscall.EV_ONESHOT
    }
    // 根据不同的event进行不同的赋值，然后注册到 Kqueue/Epoll 中
    _, err := syscall.Kevent(p.fd, evs, nil, nil)
    return err
}
```
这里可以看到，当服务启动的时候，注册的是socketFd的读事件，同时会将整个operator传入到Udata中，下面我们开始分析处理方法

## pool.Wait
pool.Wait 是进行连接处理的主逻辑
```go
// Wait implements Poll.
func (p *defaultPoll) Wait() error {
    // init
    // barriercap = 32
    var size, caps = 1024, barriercap
    /*
    type barrier struct {
        bs  [][]byte
        ivs []syscall.Iovec // io向量，用于readv和sendmsg，sendmsg中是把过个不连续的数据通过一次系统调用写入内核
    }
     */
    // 最多1024个events同时触发
    var events, barriers = make([]syscall.Kevent_t, size), make([]barrier, size)
    for i := range barriers {
        barriers[i].bs = make([][]byte, caps)
        barriers[i].ivs = make([]syscall.Iovec, caps)
    }
    // wait
    for {
        var hups []*FDOperator
        // 监听fd是否有触发
        n, err := syscall.Kevent(p.fd, nil, events, nil)
        if err != nil && err != syscall.EINTR {
            // exit gracefully
            if err == syscall.EBADF {
                return nil
            }
            return err
        }
        for i := 0; i < n; i++ {
            // trigger
            // 如果Ident==0表示用户自定义事件
            if events[i].Ident == 0 {
                // clean trigger
                // 清空标记位
                atomic.StoreUint32(&p.trigger, 0)
                continue
            }
            // 这里会拿到之前存储在Udata中的数据，因为Udata里存储的是*FDOperator，所以Udata的指针是一个**FDOperator，这个上面已经说过
            var operator = *(**FDOperator)(unsafe.Pointer(&events[i].Udata))
            // 原子操作，检查operator是否在处理其他逻辑
            if !operator.do() {
                continue
            }
            switch {
            // 如果出现关闭的，则放入hups中等待集中处理，这个在Kqueue的代码中有提到过
            case events[i].Flags&syscall.EV_EOF != 0:
                hups = append(hups, operator)
            // 读事件
            case events[i].Filter == syscall.EVFILT_READ && events[i].Flags&syscall.EV_ENABLE != 0:
                // for non-connection
                // 这里针对socketFd，调用的是server处注册的onRead，具体下面的方法进行分析
                if operator.OnRead != nil {
                    operator.OnRead(p)
                    break
                }
                // only for connection
                /*
                // inputs implements FDOperator.
                func (c *connection) inputs(vs [][]byte) (rs [][]byte) {
                    // cas是否可读，不可读则结束本次操作
                    if !c.lock(reading) {
                        return rs
                    }

                    n := int(atomic.LoadInt32(&c.waitReadSize))
                    if n <= pagesize {
                        return c.inputBuffer.Book(pagesize, vs)
                    }

                    n -= c.inputBuffer.Len()
                    if n < pagesize {
                        n = pagesize
                    }
                    return c.inputBuffer.Book(n, vs)
                }
                 */
                // 获取一个读缓存
                var bs = operator.Inputs(barriers[i].bs)
                if len(bs) == 0 {
                    break
                }
                // 系统调用readv，读取内容到ivs中，readv与read的区别是readv读可以将读到的数据放入多个不连续的缓存中（iovec）
                var n, err = readv(operator.FD, bs, barriers[i].ivs)
                /*
                // inputAck implements FDOperator.
                func (c *connection) inputAck(n int) (err error) {
                    if n < 0 {
                        n = 0
                    }
                    lack := atomic.AddInt32(&c.waitReadSize, int32(-n))
                    err = c.inputBuffer.BookAck(n, lack <= 0)
                    c.unlock(reading)
                    c.triggerRead()
                    c.onRequest()
                    return err
                }
                 */
                // 触发读取，然后会开一个线程处理之前定义的onRequest
                operator.InputAck(n)
                if err != nil && err != syscall.EAGAIN && err != syscall.EINTR {
                    log.Printf("readv(fd=%d) failed: %s", operator.FD, err.Error())
                    hups = append(hups, operator)
                }
            // 写事件
            case events[i].Filter == syscall.EVFILT_WRITE && events[i].Flags&syscall.EV_ENABLE != 0:
                // for non-connection
                // 针对socket
                if operator.OnWrite != nil {
                    operator.OnWrite(p)
                    break
                }
                // only for connection
                // 返回写的数据和是否使用零拷贝
                var bs, supportZeroCopy = operator.Outputs(barriers[i].bs)
                if len(bs) == 0 {
                    break
                }
                // TODO: Let the upper layer pass in whether to use ZeroCopy.
                // 发送数据
                var n, err = sendmsg(operator.FD, bs, barriers[i].ivs, false && supportZeroCopy)
                // 等待数据发送完成，然后释放缓存
                operator.OutputAck(n)
                if err != nil && err != syscall.EAGAIN {
                    log.Printf("sendmsg(fd=%d) failed: %s", operator.FD, err.Error())
                    hups = append(hups, operator)
                }
            }
            operator.done()
        }
        // hup conns together to avoid blocking the poll.
        if len(hups) > 0 {
            p.detaches(hups)
        }
    }
}
```

## onRead
```go
// OnRead implements FDOperator.
func (s *server) OnRead(p Poll) error {
    // accept socket
    conn, err := s.ln.Accept()
    if err != nil {
        // shut down
        // socketFD出现错误 
        if strings.Contains(err.Error(), "closed") {
            // 关闭时，会通过Control关闭注册在poll的事件
            s.operator.Control(PollDetach)
            s.quit(err)
            return err
        }
        log.Println("accept conn failed:", err.Error())
        return err
    }
    if conn == nil {
        return nil
    }
    // store & register connection
    // 保存连接信息
    var connection = &connection{}
    // 初始化连接，会调用之前server注册的prepare
    // init 方法见下面
    connection.init(conn.(Conn), s.prepare)
    if !connection.IsActive() {
        return nil
    }
    var fd = conn.(Conn).Fd()
    // 添加回调
    connection.AddCloseCallback(func(connection Connection) error {
        s.connections.Delete(fd)
        return nil
    })
    // 将连接保存
    s.connections.Store(fd, connection)
    return nil
}

// init arguments: conn is required, prepare is optional.
func (c *connection) init(conn Conn, prepare OnPrepare) (err error) {
    // conn must be *netFD{}
    // 检测conn是一个*netFD类型
    // 同时会将c.netFD进行赋值
    c.checkNetFD(conn)

    // 初始化FD，主要初始化c.operator，
    c.initFDOperator()
    // 设置为非阻塞
    syscall.SetNonblock(c.fd, true)

    // init buffer, barrier, finalizer
    c.readTrigger = make(chan int, 1)
    // 创建[]byte buffer
    c.inputBuffer, c.outputBuffer = NewLinkBuffer(pagesize), NewLinkBuffer()
    // 创建barrier（无拷贝）
    c.inputBarrier, c.outputBarrier = barrierPool.Get().(*barrier), barrierPool.Get().(*barrier)
    c.setFinalizer()

    // check zero-copy
    // setZeroCopy 会调用syscall.SetsockoptInt设置socket opt
    /*
    func setZeroCopy(fd int) error {
        // 第一个参数是fd，第二个参数是level，如果要设置，必须为SOL_SOCKET，第三个参数是name，第四个参数是value
        return syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, SO_ZEROCOPY, 1)
    }
     */
    // 关于0拷贝的文章，可以看最后面的参考
    // setBlockZeroCopySend 设置超时时间
    // 当前只有linux使用0拷贝，freebsd/darwin 则不使用
    // 另外MSG_ZEROCOPY的方式只用于send数据
    if setZeroCopy(c.fd) == nil && setBlockZeroCopySend(c.fd, defaultZeroCopyTimeoutSec, 0) == nil {
        c.supportZeroCopy = true
    }
    // 调用prepare方法，然后从pollmanager中获取一个poll，然后调用pool.Control
    return c.onPrepare(prepare)
}
```
## 总结
字节跳动开源的netpoll底层相较于evio来说，主要优化了数据的读取与发送，同时使用线程池来处理用户逻辑，
难度主要集中在零拷贝和读写处理上。本次分析这块的细节没有好好了解，有时间再细品。

## 题外分享
- [Linux I/O 原理和 Zero-copy 技术全面揭秘](https://zhuanlan.zhihu.com/p/308054212)
- [原来 8 张图，就可以搞懂「零拷贝」了](https://www.cnblogs.com/xiaolincoding/p/13719610.html)
- [Linux Socket 0拷贝特性](https://zhuanlan.zhihu.com/p/28575308)
