# CONTEXT

translate.nvim 的领域术语表。只收录已达成共识的词汇,不含实现细节。

## 术语

- **段落(Paragraph)**:空行分隔的连续文本块,是悬浮翻译的基本单位。边界情况(代码块、列表等)的语义见工单「段落检测与选区语义」,落定后回写此处。
- **Provider(翻译引擎)**:对某个 LLM API 的适配器,实现统一的翻译接口。内置 OpenAI-compatible 与 Gemini 两种;用户可注册自定义 provider。
- **悬浮译文窗(Translation Float)**:锚定在段落附近、流式渲染译文的浮动窗口。
- **手动触发(Manual Trigger)**:用户按 keymap 对光标所在段落发起翻译,是默认交互。
- **自动触发(Auto Trigger)**:`CursorHold` 驱动的可选模式,光标停留后自动翻译。
- **目标语言(Target Language)**:译文语言,可配置,默认中文;源语言不配置,由 LLM 自动识别。
