---
title: "Multicall使用和原理 (WIP)"
date: 2021-12-02
lastmod: 2021-12-02
draft: false
tags: ["合约", "Blockchain", "Solidity"]

toc: true

---

## 前言
公司的小伙伴在做一些数据分析的时候用到了`multicall`，于是就研究了一下，分享一下multicall的使用和原理

## 开始之前需要知道的关于 ETH-JsonRPC的事情
ETH提供两种调用合约的方法：
- eth_sendTransaction
  - 这种方法
- eth_call


