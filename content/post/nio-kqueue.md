---
title: "NIO-Kqueue"
date: 2021-07-16
lastmod: 2021-07-16
draft: false
tags: ["nio", "net", "golang"]

toc: true

---

## 关键字

- Kqueue
- Kevent
- Kevent_t

## Kqueue

创建一个kqueue监听队列，返回的是kq的文件描述符

```go
kq, err := syscall.Kqueue()
```

## Kevent

监听方法，kq监听changes里注册的事件，将触发的事件放入events

```go
func Kevent(
    kq int,             // kqueue的fd
    changes,            // 注册监听的事件
    events []Kevent_t,  // 当事件触发后，会放入这个数组中
    timeout *Timespec   // 超时处理
) (
    n int,              // 触发的事件的数量
    err error           // 错误
)
```

Kevent 如果没有设置timeout或events不为空，则会阻塞，直到注册事件触发。当有事件触发时，返回n是触发的事件的个数，可以通过events获取触发的事件

## Kevent_t

Kevent_t 是定义事件的结构体

```go
type Kevent_t struct {
    Ident  uint64 // 事件的标记，一般为文件描述符
    Filter int16  // 事件触发的条件，比如读就绪时触发，写就绪时触发, prefix为 EVFILT_
    Flags  uint16 // 事件的操作，比如添加事件，删除此事件，prefix为 EV_
    Fflags uint32 // filter中的一些额外标记
    Data   int64  // filter中的一些额外信息
    Udata  *byte  // 用户自定义的信息，会通过内核传递出去
}   
```

## 一个简单的网络nio

下面是一个简单的网路nio，接收tcp连接，然后读取传送过来的数据

```go
func NetworkNIO() {
    // 创建一个socket
    listener, _ := net.Listen("unix", "./chuwt.socket")
    defer listener.Close()

    var fd int

    // 获取此socket的FD
    f, err := listener.(*net.UnixListener).File()
    if err != nil {
        log.Println("get listener fd error", err)
        return
    }
    fd = int(f.Fd())
    // 设置FD为非阻塞
    _ = syscall.SetNonblock(fd, true)

    // 创建一个Kqueue
    kqFd, err := syscall.Kqueue()
    if err != nil {
        log.Println("create kqueue error", err)
        return
    }
    // 注册socket的读事件
    _, err = syscall.Kevent(kqFd, []syscall.Kevent_t{
        {
            Ident:  uint64(fd),
            Filter: syscall.EVFILT_READ, // 读就绪触发
            Flags: syscall.EV_ADD | // 添加
                syscall.EV_CLEAR, // 当触发后，events会清空
        },
    }, nil, nil)
    if err != nil {
        log.Println("create kqueue error", err)
        return
    }
    events := make([]syscall.Kevent_t, 100)
    for {
        n, err := syscall.Kevent(kqFd, nil, events, nil)
        if err != nil && err != syscall.EINTR {
            log.Println("an error occurred", err)
            return
        }
        for i := 0; i < n; i++ {
            event := events[i]
            eventFd := int(event.Ident)
            if event.Flags | syscall.EV_EOF == event.Flags {
                // 退出了
                _ = syscall.Close(eventFd)
                // 移除
                _, _ = syscall.Kevent(kqFd, []syscall.Kevent_t{
                    {
                        Ident:  uint64(eventFd),
                        Flags:  syscall.EV_DELETE,
                        Filter: syscall.EVFILT_READ, // 监听读
                    },
                }, nil, nil)
                log.Println("连接", eventFd, "退出")
                continue
            }
            if eventFd == fd {
                // socket的文件描述符
                connFd, _, err := syscall.Accept(eventFd)
                if err != nil {
                    if err == syscall.EAGAIN {
                        continue
                    } else {
                        _ = syscall.Close(connFd)
                    }
                    continue
                }
                log.Println("收到连接请求:", connFd)
                _ = syscall.SetNonblock(connFd, true)
                // 将新连接加入到监听中
                // 这里只注册读事件，可以注册写事件
                _, err = syscall.Kevent(kqFd, []syscall.Kevent_t{
                    {
                        Ident:  uint64(connFd),
                        Flags:  syscall.EV_ADD,
                        Filter: syscall.EVFILT_READ, // 监听读
                    },
                }, nil, nil)
                if err != nil {
                    _ = syscall.Close(connFd)
                }

            } else {
                // 连接的fd就绪了
                // 创建一个buf进行读取
                buf := make([]byte, 100)
                // 读
                rn, err := syscall.Read(eventFd, buf)
                if err != nil {
                    if err == syscall.EAGAIN {
                        continue
                    } else {
                        log.Println("read error:", err)
                        continue
                    }
                } else if rn == 0 {

                }
                fmt.Println("收到:", eventFd, "的信息:", string(buf))
            }
        }
    }
}
```

