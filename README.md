# 考试打铃 - iOS App

粘贴考试时间表 → 自动解析 → 一键设置/取消闹钟

## 功能

- 粘贴考试时间文本（支持一行一行复制粘贴或直接粘贴整段）
- 自动识别日期、时间、打铃描述
- 一键创建全部闹钟（使用系统日历提醒）
- 一键取消特定日期的全部闹钟
- 支持整体时间偏移

## 支持的输入格式

```
6月13日上午
08:40第一次打铃(组织考生进入考室)
09:00第二次打铃(考试开始、禁止迟到考生入场)
...
6月13日下午
14:40第一次打铃(组织考生进入考室)
...
```

## 构建方式

### 本地构建 (macOS + Xcode)

```bash
# 安装 XcodeGen
brew install xcodegen

# 生成 Xcode 项目
xcodegen generate

# 在 Xcode 中打开
open ExamBell.xcodeproj
```

### GitHub Actions CI/CD

推送代码后自动构建 IPA：

1. Fork / 推送此仓库到 GitHub
2. Actions 自动触发构建
3. 下载 `ExamBell-unsigned` artifact
4. 用 **iLoader** 签名安装

## 安装到 iPhone

1. 从 GitHub Actions 下载 IPA
2. 导入 **iLoader** (证书签名 → IPA 签名)
3. 安装到设备

## 技术栈

- SwiftUI
- EventKit (日历提醒)
- XcodeGen (项目生成)
- GitHub Actions (CI/CD)
