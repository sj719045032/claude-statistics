export const languages = ["en", "zh"] as const;

export type Language = (typeof languages)[number];

type NavKey = "features" | "capabilities" | "accounts" | "gallery" | "download";
type SectionKey =
  | "hero"
  | "proof"
  | "features"
  | "capabilities"
  | "accounts"
  | "share"
  | "integrations"
  | "gallery"
  | "cta"
  | "footer";

type SiteCopy = {
  langLabel: string;
  switchLabel: string;
  meta: {
    title: string;
    description: string;
  };
  nav: Record<NavKey, string>;
  common: {
    github: string;
    release: string;
    screenshots: string;
    source: string;
    allProviders: string;
    usageWindows: string;
    localFirst: string;
    managedAccounts: string;
  };
  hero: {
    eyebrow: string;
    title: string;
    text: string;
    points: string[];
    summaryTitle: string;
    summaryText: string;
    usageTitle: string;
    floatingTitle: string;
  };
  proofStats: Array<{ value: string; label: string }>;
  features: {
    eyebrow: string;
    title: string;
    cards: Array<{ kicker: string; title: string; text: string; accent?: boolean; large?: boolean }>;
  };
  capabilities: {
    eyebrow: string;
    title: string;
    cards: Array<{ kicker: string; title: string; items: string[] }>;
  };
  accounts: {
    eyebrow: string;
    title: string;
    text: string;
    items: string[];
    demo: Array<{ provider: string; title: string; status: string; active?: boolean }>;
  };
  share: {
    eyebrow: string;
    title: string;
    text: string;
    items: string[];
    metrics: Array<{ value: string; label: string }>;
  };
  integrations: {
    eyebrow: string;
    title: string;
    cards: Array<{ kicker: string; title: string; text: string }>;
  };
  gallery: {
    eyebrow: string;
    title: string;
    items: Array<{ src: string; alt: string; caption: string }>;
  };
  cta: {
    eyebrow: string;
    title: string;
    text: string;
  };
  footer: {
    left: string;
    right: string;
  };
};

export const siteCopy: Record<Language, SiteCopy> = {
  en: {
    langLabel: "English",
    switchLabel: "中文",
    meta: {
      title: "Claude Statistics | Native macOS analytics for AI coding sessions",
      description:
        "Track Claude Code, Codex CLI, and Gemini CLI sessions, quotas, accounts, tokens, and cost in one native macOS menu bar app."
    },
    nav: {
      features: "Features",
      capabilities: "Capabilities",
      accounts: "Accounts",
      gallery: "Gallery",
      download: "Download"
    },
    common: {
      github: "GitHub",
      release: "Download latest release",
      screenshots: "See screenshots",
      source: "Browse source",
      allProviders: "All providers",
      usageWindows: "Usage windows",
      localFirst: "Local-first",
      managedAccounts: "Managed Accounts"
    },
    hero: {
      eyebrow: "Native analytics for serious AI workflows",
      title: "See every token, quota window, and session arc without leaving your menu bar.",
      text:
        "Claude Statistics turns local AI coding history into a polished macOS command center for Claude Code, Codex CLI, and Gemini CLI.",
      points: ["Local-first transcript parsing", "Quota and cost monitoring", "Multi-account and CLI switching"],
      summaryTitle: "Claude + Codex + Gemini",
      summaryText: "Switch providers instantly and keep each parsing pipeline running independently.",
      usageTitle: "5h / 7d / grouped quota tracking",
      floatingTitle: "Analytics from transcripts you already own"
    },
    proofStats: [
      { value: "3", label: "AI coding providers in one app" },
      { value: "53-week", label: "heatmap and all-time trends" },
      { value: "Local", label: "parsing, search, and cost analysis" },
      { value: "9 + 11", label: "share roles and unlockable badges" }
    ],
    features: {
      eyebrow: "Why it feels different",
      title: "A native-feeling command center with the visual confidence of a modern product site.",
      cards: [
        {
          kicker: "Session intelligence",
          title: "Search transcripts, inspect tools, and jump back into the exact project context.",
          text: "Browse grouped sessions, inspect token and model breakdowns, and reopen work in your preferred terminal.",
          large: true
        },
        {
          kicker: "Usage visibility",
          title: "Track live quota pressure before a workflow stalls.",
          text: "Follow 5-hour and 7-day Claude windows, Gemini grouped buckets, and menu bar status at a glance."
        },
        {
          kicker: "All-time analytics",
          title: "See the shape of your work over weeks, months, and bursts.",
          text: "Heatmaps, project rankings, trend charts, and cost distribution turn raw transcripts into signal."
        },
        {
          kicker: "Provider-aware design",
          title: "Claude, Codex, and Gemini each keep their own parsing and account model.",
          text: "Provider switching feels instant without stopping background indexing for the others."
        },
        {
          kicker: "Account switching",
          title: "Swap live Claude, Codex, or Gemini identities without digging through dotfiles.",
          text: "Changing CLI identity becomes a product feature, not a shell ritual."
        },
        {
          kicker: "Share cards",
          title: "Turn deep usage history into polished, data-backed bragging rights.",
          text: "Generate role-driven cards with badges, proof metrics, and export-ready visuals.",
          accent: true
        }
      ]
    },
    capabilities: {
      eyebrow: "What the app actually covers",
      title: "More than a dashboard: session control, transcript search, provider switching, and operational detail.",
      cards: [
        {
          kicker: "Notch Island",
          title: "Live activity surface for every running session.",
          items: [
            "Active sessions grouped by project with live status (waiting / working / awaiting approval)",
            "Inline Allow / Deny cards for Claude Code permission requests, written back through the hook protocol",
            "One-keystroke focus return to the exact Ghostty surface / iTerm2 / Terminal tab"
          ]
        },
        {
          kicker: "Session control",
          title: "Recent sessions, grouped projects, hover actions, and fast resume flows.",
          items: [
            "Search by path, topic, session name, or session ID",
            "Resume, start new, delete, batch delete, and copy path quickly",
            "Real-time file watching where provider formats allow it"
          ]
        },
        {
          kicker: "Transcript viewer",
          title: "Read conversations in-app instead of opening raw JSONL or CLI files.",
          items: [
            "Tool-call aware rendering with role-specific transcript display",
            "Match navigation, highlight, and Markdown code block support",
            "Better visibility into what tools were actually used"
          ]
        },
        {
          kicker: "Analytics",
          title: "All-time, daily, weekly, and monthly views with real cost signal.",
          items: [
            "Heatmap, project rankings, period drill-down, and trend charts",
            "Token, model, cache-read, and cache-write breakdowns",
            "Context usage and per-session model distribution"
          ]
        },
        {
          kicker: "Quota monitoring",
          title: "Watch usage windows before they surprise you mid-flow.",
          items: [
            "Claude 5h and 7d tracking plus provider-aware menu bar status",
            "Gemini grouped quota buckets and local usage trends",
            "Auto-refresh, retry states, and clearer local usage visibility"
          ]
        }
      ]
    },
    accounts: {
      eyebrow: "Accounts and CLI identity",
      title: "Switch accounts inside the app, including the underlying CLI account it activates.",
      text:
        "Claude Statistics can keep managed accounts for Claude, Codex, and Gemini, then switch the live account used by that provider when you choose another identity.",
      items: [
        "Add new provider accounts from Settings instead of manually editing auth files",
        "Switch the active Claude, Codex, or Gemini CLI identity from the same panel",
        "Keep provider switching and account switching separate so tool and user can change independently",
        "Pair each workflow with your preferred terminal for fast session resume"
      ],
      demo: [
        { provider: "Claude", title: "jinshi.tinystone@gmail.com", status: "Live now", active: true },
        { provider: "Claude", title: "719045032@qq.com", status: "Saved account" },
        { provider: "Codex", title: "Switch CLI identity on demand", status: "Managed in app" },
        { provider: "Gemini", title: "Separate provider home and account state", status: "Ready to activate" }
      ]
    },
    share: {
      eyebrow: "Share preview",
      title: "Turn heavy usage history into a polished identity card people will actually remember.",
      text:
        "Share Preview is not a generic export. It composes role labels, badge unlocks, cost and token proof, project coverage, and a QR-ready layout into something worth posting.",
      items: [
        "9 role archetypes and 11 unlockable badges based on actual usage patterns",
        "Native-resolution PNG export plus copy, save, and social share actions",
        "Built-in QR block so a card can point back to your repo, profile, or launch post"
      ],
      metrics: [
        { value: "9", label: "role archetypes" },
        { value: "11", label: "badge unlocks" },
        { value: "PNG", label: "native export" }
      ]
    },
    integrations: {
      eyebrow: "Settings and integrations",
      title: "The operational layer matters too: terminals, pricing, refresh rules, status lines, and updates.",
      cards: [
        {
          kicker: "Workflow settings",
          title: "Preferred terminal, launch-at-login, language, font scale, and tab order.",
          text: "Built for daily use, not one-off inspection."
        },
        {
          kicker: "Pricing and status line",
          title: "Edit model pricing, fetch updates, and install provider-specific status line integrations.",
          text: "Useful when you care about cost fidelity and want CLI context visible before opening the app."
        },
        {
          kicker: "Diagnostics and updates",
          title: "Export diagnostics, inspect failures, and stay current with Sparkle-based updates.",
          text: "A tool you can trust operationally, not just a pretty layer over transcript files."
        },
        {
          kicker: "Share system",
          title: "9 roles, 11 badges, QR code embeds, and native-resolution PNG export.",
          text: "Share cards turn usage history into something visual enough for social posts and team chats."
        }
      ]
    },
    gallery: {
      eyebrow: "Product gallery",
      title: "Everything important stays one click away.",
      items: [
        {
          src: "/docs/screenshots/hero-overview.png",
          alt: "Claude Statistics overview interface",
          caption: "Overview cards, provider context, and polished menu bar workflow."
        },
        {
          src: "/docs/screenshots/statistics-overview.png",
          alt: "Statistics overview with charts and insights",
          caption: "All-time statistics with ranked projects, period drill-down, and heatmap context."
        },
        {
          src: "/docs/screenshots/session-detail.png",
          alt: "Session detail view with token analytics",
          caption: "Per-session analysis with token distribution, tools, models, and timing."
        },
        {
          src: "/docs/screenshots/transcript-search.png",
          alt: "Transcript search inside the app",
          caption: "Search full conversations and tool calls without opening raw transcript files."
        },
        {
          src: "/docs/screenshots/usage-hover.png",
          alt: "Quota usage chart with hover details",
          caption: "Inspect quota windows with crosshair tooltips, grouped metrics, and trend visibility."
        }
      ]
    },
    cta: {
      eyebrow: "Ready to ship",
      title: "Download the app or inspect the source.",
      text: "Install the latest DMG from GitHub Releases, or clone the repository and build it locally with XcodeGen and Xcode 16+."
    },
    footer: {
      left: "Claude Statistics · Native macOS menu bar app · Built for serious AI workflows · MIT open source",
      right: "Built for people who use Claude Code, Codex CLI, and Gemini CLI enough to care about context, cost, and momentum."
    }
  },
  zh: {
    langLabel: "中文",
    switchLabel: "English",
    meta: {
      title: "Claude Statistics | 原生 macOS AI 编码会话分析工具",
      description:
        "在一个原生 macOS 菜单栏应用里统一查看 Claude Code、Codex CLI 和 Gemini CLI 的会话、配额、账号、Token 与成本。"
    },
    nav: {
      features: "亮点",
      capabilities: "能力",
      accounts: "账号",
      gallery: "截图",
      download: "下载"
    },
    common: {
      github: "GitHub",
      release: "下载最新版本",
      screenshots: "查看截图",
      source: "查看源码",
      allProviders: "全平台支持",
      usageWindows: "配额窗口",
      localFirst: "本地优先",
      managedAccounts: "托管账号"
    },
    hero: {
      eyebrow: "为重度 AI 工作流打造的原生分析工具",
      title: "在菜单栏里看清 Token、配额窗口和会话轨迹。",
      text:
        "Claude Statistics 把本地 AI 编码历史整理成一个精致、快速、原生的 macOS 控制中心，统一覆盖 Claude Code、Codex CLI 和 Gemini CLI。",
      points: ["本地优先的 transcript 解析", "配额与成本监控", "多账号与 CLI 账号切换"],
      summaryTitle: "Claude + Codex + Gemini",
      summaryText: "随时切换 provider，同时保留各自独立的解析与缓存管线。",
      usageTitle: "5h / 7d / 分组配额追踪",
      floatingTitle: "从你已拥有的 transcript 里提炼分析结果"
    },
    proofStats: [
      { value: "3", label: "一个应用覆盖三种 AI 编码工具" },
      { value: "53 周", label: "热力图与全时段趋势分析" },
      { value: "本地", label: "解析、搜索与成本分析都在本机完成" },
      { value: "9 + 11", label: "角色卡与可解锁徽章系统" }
    ],
    features: {
      eyebrow: "为什么它看起来不一样",
      title: "既有原生工具的质感，也有现代产品官网该有的视觉张力。",
      cards: [
        {
          kicker: "会话 intelligence",
          title: "搜索 transcript、查看工具调用，并回到准确的项目上下文继续工作。",
          text: "你可以浏览分组会话、查看 token 和模型拆分，并用偏好的终端一键恢复工作流。",
          large: true
        },
        {
          kicker: "配额可见性",
          title: "在工作流被打断前，先看到实时配额压力。",
          text: "快速查看 Claude 的 5 小时与 7 天窗口、Gemini 分组 quota，以及菜单栏状态。"
        },
        {
          kicker: "全时段分析",
          title: "按周、按月、按爆发期看清你的使用节奏。",
          text: "热力图、项目排名、趋势图和成本分布，把原始 transcript 变成可读信号。"
        },
        {
          kicker: "Provider 感知设计",
          title: "Claude、Codex、Gemini 各自维护独立的解析和账号模型。",
          text: "切换 provider 时足够快，同时不会中断其他 provider 的后台索引。"
        },
        {
          kicker: "账号切换",
          title: "不用翻 dotfiles，也能切换 Claude、Codex 或 Gemini 的在线账号。",
          text: "CLI 账号切换直接变成产品能力，而不是终端里的手工流程。"
        },
        {
          kicker: "分享卡",
          title: "把深度使用历史变成精致、可证明的个人战绩卡。",
          text: "角色化卡片、徽章、证据指标和导出图，一次都准备好。",
          accent: true
        }
      ]
    },
    capabilities: {
      eyebrow: "它到底覆盖了什么",
      title: "不只是一个 dashboard，而是会话控制、搜索、切换和运营细节的完整工具面。",
      cards: [
        {
          kicker: "刘海岛",
          title: "所有在跑的会话实时活动面板。",
          items: [
            "按项目分组的在跑会话列表，实时状态（等待输入 / 工作中 / 等待审批）",
            "Claude Code 权限请求内联 Allow / Deny 卡片，回写到 hook 协议，全程不切终端",
            "一键跳回 Ghostty 精确 surface / iTerm2 tty / Terminal tab"
          ]
        },
        {
          kicker: "会话控制",
          title: "最近会话、项目分组、hover 操作和快速恢复流程。",
          items: [
            "按路径、主题、会话名或 session ID 搜索",
            "快速恢复、新建、删除、批量删除、复制路径",
            "在 provider 格式允许时支持实时文件监听"
          ]
        },
        {
          kicker: "Transcript 查看器",
          title: "直接在应用里读对话，不再手动翻 JSONL 或 CLI 文件。",
          items: [
            "带工具调用语义的 transcript 渲染",
            "匹配跳转、高亮、Markdown 与代码块支持",
            "更容易看清到底用了哪些工具"
          ]
        },
        {
          kicker: "统计分析",
          title: "全时段、日、周、月多维度统计，真正看到成本信号。",
          items: [
            "热力图、项目排名、周期 drill-down 与趋势图",
            "Token、模型、cache read、cache write 拆分",
            "上下文使用率与单会话模型分布"
          ]
        },
        {
          kicker: "配额监控",
          title: "在中途撞 quota 之前，先看到风险变化。",
          items: [
            "Claude 5 小时 / 7 天窗口与菜单栏动态状态",
            "Gemini 分组 quota 与本地趋势图",
            "自动刷新、重试状态与本地使用趋势"
          ]
        }
      ]
    },
    accounts: {
      eyebrow: "账号与 CLI 身份",
      title: "在应用里切账号，同时切换底层实际激活的 CLI 账号。",
      text:
        "Claude Statistics 不只是显示当前登录状态。它可以保存 Claude、Codex、Gemini 的托管账号，并在你选择后切换对应 provider 当前生效的 live account。",
      items: [
        "在设置页添加 provider 账号，而不是手改认证文件",
        "直接切换 Claude、Codex、Gemini 当前激活的 CLI 账号",
        "provider 切换与账号切换彼此独立，工具和身份可以分别调整",
        "结合偏好终端，让恢复工作流更自然"
      ],
      demo: [
        { provider: "Claude", title: "jinshi.tinystone@gmail.com", status: "当前生效", active: true },
        { provider: "Claude", title: "719045032@qq.com", status: "已保存账号" },
        { provider: "Codex", title: "按需切换 CLI 身份", status: "应用内管理" },
        { provider: "Gemini", title: "独立 provider home 与账号状态", status: "随时可激活" }
      ]
    },
    share: {
      eyebrow: "分享卡预览",
      title: "把高强度使用历史变成一张别人真的会记住的身份卡。",
      text:
        "Share Preview 不是普通导出图。它会把角色标签、徽章解锁、成本与 Token 证据、项目覆盖度，以及可扫码的版式组合成一张值得分享的卡片。",
      items: [
        "基于真实使用模式生成 9 种角色和 11 个可解锁徽章",
        "支持原生分辨率 PNG 导出，也支持复制、保存和社交分享",
        "内置二维码区域，可以指向仓库、主页或发布链接"
      ],
      metrics: [
        { value: "9", label: "角色原型" },
        { value: "11", label: "徽章解锁" },
        { value: "PNG", label: "原生导出" }
      ]
    },
    integrations: {
      eyebrow: "设置与集成",
      title: "真正重要的还有这些：终端、定价、刷新策略、状态栏集成和更新机制。",
      cards: [
        {
          kicker: "工作流设置",
          title: "偏好终端、开机启动、语言、字号和 Tab 顺序。",
          text: "它不是一次性查看器，而是适合每天常驻使用的工具。"
        },
        {
          kicker: "定价与状态栏",
          title: "编辑模型定价、获取更新，并安装 provider 专属状态栏集成。",
          text: "当你真的在意成本精度和 CLI 上下文时，这些会很有价值。"
        },
        {
          kicker: "诊断与更新",
          title: "导出诊断信息、定位失败原因，并通过 Sparkle 获取更新。",
          text: "它需要在运营层面也足够可信，而不是只会展示数据。"
        },
        {
          kicker: "分享系统",
          title: "9 种角色、11 个徽章、二维码嵌入和原生分辨率 PNG 导出。",
          text: "让使用记录足够适合发社交媒体、团队群或个人主页。"
        }
      ]
    },
    gallery: {
      eyebrow: "产品截图",
      title: "重要信息都应该在一两次点击内到达。",
      items: [
        {
          src: "/docs/screenshots/hero-overview.png",
          alt: "Claude Statistics 总览界面",
          caption: "总览卡片、provider 上下文和打磨过的菜单栏工作流。"
        },
        {
          src: "/docs/screenshots/statistics-overview.png",
          alt: "统计总览与图表",
          caption: "全时段统计、项目排名、周期钻取和热力图。"
        },
        {
          src: "/docs/screenshots/session-detail.png",
          alt: "单会话分析页面",
          caption: "查看 token 分布、工具调用、模型使用和时间信息。"
        },
        {
          src: "/docs/screenshots/transcript-search.png",
          alt: "Transcript 搜索界面",
          caption: "无需手动打开原始文件，也能搜索完整对话与工具调用。"
        },
        {
          src: "/docs/screenshots/usage-hover.png",
          alt: "配额趋势图与悬浮信息",
          caption: "查看 quota 窗口、分组指标和趋势细节。"
        }
      ]
    },
    cta: {
      eyebrow: "已经可以开始",
      title: "下载应用，或者先看源码。",
      text: "你可以直接从 GitHub Releases 安装 DMG，也可以用 XcodeGen 和 Xcode 16+ 在本地构建。"
    },
    footer: {
      left: "Claude Statistics · 原生 macOS 菜单栏应用 · 为重度 AI 工作流打造 · MIT 开源",
      right: "适合那些真正频繁使用 Claude Code、Codex CLI 和 Gemini CLI，并且在意上下文、成本和节奏的人。"
    }
  }
};

export function getAlternateLanguage(language: Language): Language {
  return language === "en" ? "zh" : "en";
}
