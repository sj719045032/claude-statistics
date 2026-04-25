import type { Language } from "./site";

export type FeatureSlug =
  | "sessions"
  | "analytics"
  | "usage"
  | "notch-island"
  | "accounts"
  | "share";

export const featureSlugs: FeatureSlug[] = [
  "sessions",
  "analytics",
  "usage",
  "notch-island",
  "accounts",
  "share"
];

export type Capability = {
  num: string;
  title: string;
  text: string;
};

export type HowToStep = {
  heading: string;
  text: string;
};

export type Scenario = {
  title: string;
  text: string;
};

export type FeatureDetail = {
  slug: FeatureSlug;
  eyebrow: string;
  title: string;
  lede: string;
  heroImage: string | null;
  heroImageAlt: string;
  hubKicker: string;
  hubTitle: string;
  hubBlurb: string;
  hubBullets: string[];
  capabilities: [Capability, Capability, Capability];
  howItWorks: {
    title: string;
    intro: string;
    steps: HowToStep[];
  };
  scenarios: {
    title: string;
    items: Scenario[];
  };
  related: FeatureSlug[];
};

const en: Record<FeatureSlug, FeatureDetail> = {
  sessions: {
    slug: "sessions",
    eyebrow: "01 · Sessions & Transcript",
    title: "Every session, every tool call, fully searchable.",
    lede:
      "Browse transcripts from ~/.claude, ~/.codex and ~/.gemini grouped by working directory. Full-text search across the entire archive, with tool calls classified, color-coded and easy to read.",
    heroImage: "/docs/screenshots/transcript-search.png",
    heroImageAlt: "Transcript search inside Claude Statistics with classified tool calls",
    hubKicker: "01 · Sessions",
    hubTitle: "Search every transcript you already own.",
    hubBlurb:
      "Folded session list, tool-aware transcript viewer, ⌘F full-text search. Reopen the exact project with a hover menu.",
    hubBullets: [
      "Sessions grouped by working directory with model and token badges",
      "Tool calls rendered with role color, Markdown and code highlighting",
      "FTS-backed search across the whole archive with snippet hits"
    ],
    capabilities: [
      {
        num: "01",
        title: "Project-folded session list",
        text:
          "Sessions are grouped by working directory. Hover for resume, copy path, delete, batch delete. Live file watching where the provider format allows it."
      },
      {
        num: "02",
        title: "Tool-aware transcript viewer",
        text:
          "User, assistant and each tool call get distinct colors. Markdown renders, code blocks highlight, and you can navigate match-by-match without losing scroll position."
      },
      {
        num: "03",
        title: "Whole-archive search",
        text:
          "⌘F searches the full body of every transcript across providers using SQLite FTS. Results show project, time and the exact snippet that matched."
      }
    ],
    howItWorks: {
      title: "How it works",
      intro:
        "Claude Statistics indexes transcript files locally — no upload, no remote service. The file watcher refreshes the index as new turns are appended.",
      steps: [
        {
          heading: "Local discovery",
          text:
            "On launch, the app walks ~/.claude, ~/.codex and ~/.gemini, then keeps watching them via FSEvents."
        },
        {
          heading: "JSONL parsing",
          text:
            "Each turn is parsed once and cached. Codex's WAL/SHM sidecar files are reconciled before parsing so live sessions stay readable."
        },
        {
          heading: "FTS index",
          text:
            "Snippet matching uses SQLite FTS5. Queries return ranked hits across every provider in a single pass."
        }
      ]
    },
    scenarios: {
      title: "Where it shines",
      items: [
        {
          title: "Find the prompt you used last month",
          text:
            "Search 'pricing migration' and Claude Statistics will surface every project where that thread happened, with timestamp and matching context."
        },
        {
          title: "Audit which tool ran when",
          text:
            "Tool-aware coloring makes it obvious whether a fix went through Edit, Bash, MultiEdit or apply_patch — across all three CLIs."
        }
      ]
    },
    related: ["analytics", "notch-island", "accounts"]
  },
  analytics: {
    slug: "analytics",
    eyebrow: "02 · All-time Analytics",
    title: "53-week heatmap. Daily rhythm. Real cost signal.",
    lede:
      "All-time, daily, weekly and monthly views aggregated across Claude Code, Codex CLI and Gemini CLI. Project rankings ordered by cost, dual-axis trend charts, model and cache distribution.",
    heroImage: "/docs/screenshots/statistics-overview.png",
    heroImageAlt: "Statistics overview with 53-week heatmap, KPI cards and trend chart",
    hubKicker: "02 · Analytics",
    hubTitle: "The shape of every week, month and burst.",
    hubBlurb:
      "Heatmap, KPI cards, project ranking, trend chart and model distribution — all from local transcripts.",
    hubBullets: [
      "53-week GitHub-style heatmap with magenta hot zones",
      "Top projects ranked by cost, with token totals and trend drill-down",
      "Cost split by model, cache read/write ratio and context pressure"
    ],
    capabilities: [
      {
        num: "01",
        title: "Heatmap that reflects real usage",
        text:
          "Hot cells are calibrated to your token throughput, not session count, so a five-minute spike doesn't look the same as a deep work day."
      },
      {
        num: "02",
        title: "Period drill-down",
        text:
          "Switch between All / Daily / Weekly / Monthly without recomputing. Click any project to expand a dual-axis trend over the same period."
      },
      {
        num: "03",
        title: "Cost-first ranking",
        text:
          "Projects are ordered by spend, not just activity. Per-row cost, token total and model split tell you where the budget actually went."
      }
    ],
    howItWorks: {
      title: "How it works",
      intro:
        "Cost is computed per-model from a pricing table you can edit. Cache read/write is tracked separately so the totals reflect what your provider actually billed.",
      steps: [
        {
          heading: "Pricing table",
          text:
            "A built-in pricing table covers Anthropic, OpenAI and Google models. You can override entries when a model is added or repriced."
        },
        {
          heading: "Local aggregation",
          text:
            "Aggregates roll up by day, week, month and project — recomputed incrementally as new turns land."
        },
        {
          heading: "Multi-provider math",
          text:
            "Token totals are kept per-provider so cross-provider charts stay meaningful even when one CLI changes its accounting."
        }
      ]
    },
    scenarios: {
      title: "Where it shines",
      items: [
        {
          title: "End of week budget check",
          text:
            "Open the Stats tab on Friday and the heatmap, project ranking and model split tell you whether the week stayed inside plan."
        },
        {
          title: "Compare two projects honestly",
          text:
            "Drill into project A and B over the same period; the dual-axis chart shows tokens vs. cost so you can spot which one is using cheaper models."
        }
      ]
    },
    related: ["usage", "sessions", "share"]
  },
  usage: {
    slug: "usage",
    eyebrow: "03 · Quota & Subscription Windows",
    title: "Know whether you'll hit the ceiling before reset.",
    lede:
      "Track Claude's 5h / 7d / per-model windows, Codex's 5h and weekly windows, Gemini's grouped Pro / Flash / Flash-Lite quotas. Green → amber → red tells you at a glance.",
    heroImage: "/docs/screenshots/usage-hover.png",
    heroImageAlt: "Usage windows with countdowns and grouped quota buckets",
    hubKicker: "03 · Usage",
    hubTitle: "Subscription windows · reset countdowns · per provider.",
    hubBlurb:
      "Live quota pressure for Claude, Codex and Gemini. Pulled from official APIs where available, computed locally otherwise.",
    hubBullets: [
      "Claude 5h / 7d / 7d-Sonnet windows from the OAuth API",
      "Codex 5h and weekly windows reconciled from the local JWT",
      "Gemini grouped quota buckets with reset-anchored trends"
    ],
    capabilities: [
      {
        num: "01",
        title: "Provider-aware windows",
        text:
          "Each CLI has its own quota model. Claude Statistics renders each one in its native shape rather than collapsing them into a fake unified view."
      },
      {
        num: "02",
        title: "Reset-anchored trend",
        text:
          "Trend charts reset at provider-defined boundaries (5h rolling, weekly Monday, daily UTC) so a fresh window starts at zero, not yesterday's value."
      },
      {
        num: "03",
        title: "Menu bar at-a-glance",
        text:
          "The icon turns amber as you approach 70% and red past 90%, so you see pressure before the workflow stalls."
      }
    ],
    howItWorks: {
      title: "How it works",
      intro:
        "Quotas are fetched from each provider's official endpoints when authenticated, then merged with locally-computed token counts so the numbers match what the CLI sees.",
      steps: [
        {
          heading: "Claude — OAuth",
          text:
            "Anthropic's OAuth API returns 5-hour, 7-day and per-model usage. Refreshed on a configurable cadence and on app focus."
        },
        {
          heading: "Codex — local JWT",
          text:
            "Codex CLI ships a JWT with the active plan; we decode it locally for plan tier and reconcile against transcript activity for usage."
        },
        {
          heading: "Gemini — grouped buckets",
          text:
            "Pro / Flash / Flash-Lite quotas are tracked as separate counters with their own reset times."
        }
      ]
    },
    scenarios: {
      title: "Where it shines",
      items: [
        {
          title: "Mid-flow window check",
          text:
            "Glance at the menu bar; if it's red, you have minutes — not hours — before reset, and you can reroute work to a different provider."
        },
        {
          title: "Weekend planning",
          text:
            "On Saturday, the 7d Sonnet window tells you whether you can spend the day on a deep refactor or whether it'll cap out before the deadline."
        }
      ]
    },
    related: ["analytics", "accounts", "notch-island"]
  },
  "notch-island": {
    slug: "notch-island",
    eyebrow: "04 · Notch Island",
    title: "A live activity surface docked to the MacBook notch.",
    lede:
      "Normally just a black notch — invisible to your workflow. When Claude Code, Codex or Gemini has something happening (waiting, working, awaiting approval), it expands. Hit Return to land in the exact terminal tab.",
    heroImage: "/notch-island.png",
    heroImageAlt: "Notch Island showing active sessions, permission card and completion",
    hubKicker: "04 · Notch Island",
    hubTitle: "Real-time session activity, where you already look.",
    hubBlurb:
      "Active sessions, inline permission cards, one-keystroke focus return — all in the MacBook notch.",
    hubBullets: [
      "Active sessions grouped by project with live status",
      "Inline Allow / Deny cards for Claude permission requests",
      "Tab-accurate jump to Ghostty / iTerm2 / Terminal"
    ],
    capabilities: [
      {
        num: "01",
        title: "Active sessions list",
        text:
          "Every running session grouped by project, with live status: waiting / working / awaiting approval. Updates in real time as hooks fire."
      },
      {
        num: "02",
        title: "Inline permission cards",
        text:
          "Claude Code permission requests surface as Allow / Deny cards. Decisions are written back through the hook protocol — you never touch the terminal."
      },
      {
        num: "03",
        title: "Tab-accurate focus return",
        text:
          "Click a card or hit Return to land in the session's exact terminal tab — Ghostty surface id, iTerm2 tty, Terminal tab all handled."
      }
    ],
    howItWorks: {
      title: "How it works",
      intro:
        "Notch Island is driven entirely by hooks. Claude Statistics installs hooks into ~/.claude/settings.json, ~/.codex/hooks.json and ~/.gemini/settings.json — events flow back as JSON over stdin.",
      steps: [
        {
          heading: "Hook events",
          text:
            "PreToolUse, PostToolUse, Notification, Stop, PermissionRequest and others — each carries the session id, project path and the relevant tool call."
        },
        {
          heading: "State aggregation",
          text:
            "The app collapses raw events into a session view: waiting on user, working on tool, awaiting approval, idle, done."
        },
        {
          heading: "Approval round-trip",
          text:
            "An Allow / Deny tap writes a JSON decision back through the hook stdin protocol. Claude resumes immediately."
        }
      ]
    },
    scenarios: {
      title: "Where it shines",
      items: [
        {
          title: "Run three sessions in parallel",
          text:
            "When session A wants approval, the notch lights up with the command; one tap lets it run, you stay in session B."
        },
        {
          title: "Glance away, come back",
          text:
            "Walk to the kitchen, glance at the notch from across the room — green dots mean waiting on you, amber means still working."
        }
      ]
    },
    related: ["sessions", "accounts", "usage"]
  },
  accounts: {
    slug: "accounts",
    eyebrow: "05 · Accounts & CLI Identity",
    title: "Switch the CLI account itself, not just a label.",
    lede:
      "Claude Statistics keeps managed accounts for Claude, Codex and Gemini, then switches the live account that the CLI uses when you pick another identity.",
    heroImage: "/docs/screenshots/hero-overview.png",
    heroImageAlt: "Provider context with managed account list and switch controls",
    hubKicker: "05 · Accounts",
    hubTitle: "Provider switching and account switching, separate by design.",
    hubBlurb:
      "Add provider accounts in Settings, swap the active CLI identity from the same panel — no manual auth file editing.",
    hubBullets: [
      "Add new provider accounts without editing dotfiles",
      "Swap the live Claude / Codex / Gemini CLI identity in-app",
      "Provider home and account state stay separate so you can change either independently"
    ],
    capabilities: [
      {
        num: "01",
        title: "Managed account roster",
        text:
          "Every Claude, Codex and Gemini account you've added shows up as a row, with current status and a one-click switch. Auth files are written atomically."
      },
      {
        num: "02",
        title: "Live identity swap",
        text:
          "Switching identity rewrites the active token / refresh credential the CLI reads — your next claude / codex / gemini invocation runs as the new user."
      },
      {
        num: "03",
        title: "Independent of provider switch",
        text:
          "Changing provider home in the menu bar is one axis; changing CLI identity is another. The two don't collide."
      }
    ],
    howItWorks: {
      title: "How it works",
      intro:
        "Each provider exposes a different auth layout — Claude's OAuth file, Codex's JWT, Gemini's settings. The app abstracts them behind a managed-account model.",
      steps: [
        {
          heading: "Capture",
          text:
            "When you log into a CLI, the app captures the credential file as a managed snapshot."
        },
        {
          heading: "Activate",
          text:
            "Selecting a saved account writes the corresponding credential atomically to the live path the CLI reads."
        },
        {
          heading: "Verify",
          text:
            "After activation, the menu bar refreshes the identity badge so you can confirm the switch took."
        }
      ]
    },
    scenarios: {
      title: "Where it shines",
      items: [
        {
          title: "Personal vs. work Claude",
          text:
            "Swap from your personal Max account to a team account in one click — without losing the personal one or copying tokens by hand."
        },
        {
          title: "Test against multiple Codex tiers",
          text:
            "Keep a Plus and a Pro account; switch to whichever has the cleaner quota window before starting a long-running session."
        }
      ]
    },
    related: ["usage", "sessions", "notch-island"]
  },
  share: {
    slug: "share",
    eyebrow: "06 · Share Cards & Roles",
    title: "Turn deep usage history into an identity card people remember.",
    lede:
      "Share Preview composes role labels, badge unlocks, cost and token proof, project coverage, and a QR-ready layout into something worth posting.",
    heroImage: null,
    heroImageAlt: "Share card preview with role and badge composition",
    hubKicker: "06 · Share",
    hubTitle: "Polished, data-backed cards from your real history.",
    hubBlurb:
      "9 role archetypes, 11 unlockable badges, native-resolution PNG export and built-in QR.",
    hubBullets: [
      "9 roles auto-derived from your usage patterns",
      "11 unlockable badges based on real activity",
      "Native PNG export plus copy, save and social share"
    ],
    capabilities: [
      {
        num: "01",
        title: "9 role archetypes",
        text:
          "Sprint Hacker, Context Beast Tamer, Efficient Operator, Night Shift Engineer, Multi-Model Director, Steady Builder, Tool Summoner, Full-Stack Pathfinder, Vibe Coding King."
      },
      {
        num: "02",
        title: "11 unlockable badges",
        text:
          "Throughput Beast, Cache Wizard, Cost Minimalist, Project Hopper and more — unlocked from concrete usage thresholds rather than handed out."
      },
      {
        num: "03",
        title: "Production-grade export",
        text:
          "Native-resolution PNG with embedded QR code, ready for Twitter, LinkedIn or a team channel post. No watermark, no upload."
      }
    ],
    howItWorks: {
      title: "How it works",
      intro:
        "Roles and badges are scored against your actual transcripts. The composition is fully local — nothing is uploaded.",
      steps: [
        {
          heading: "Score",
          text:
            "Each role has a numeric criterion (avg context ratio, night-token share, cross-project count) computed from local data."
        },
        {
          heading: "Match",
          text:
            "The top three roles surface as match percentages so the card can claim a primary identity with honest confidence."
        },
        {
          heading: "Render",
          text:
            "The poster is drawn at native resolution with the same engine the app uses for everything else — exported as PNG."
        }
      ]
    },
    scenarios: {
      title: "Where it shines",
      items: [
        {
          title: "Year-end recap",
          text:
            "Generate a card after a heavy quarter; tokens, cost and active-day coverage make it a recap people scroll past three times."
        },
        {
          title: "Team identity",
          text:
            "Each engineer's card looks distinct because it's grounded in their real patterns — not a generic template."
        }
      ]
    },
    related: ["analytics", "sessions", "usage"]
  }
};

const zh: Record<FeatureSlug, FeatureDetail> = {
  sessions: {
    slug: "sessions",
    eyebrow: "01 · 会话与 Transcript",
    title: "每个会话、每次工具调用,全部可搜。",
    lede:
      "浏览来自 ~/.claude、~/.codex、~/.gemini 的 transcript,按工作目录折叠展开。⌘F 全库 FTS 搜索,工具调用分色渲染、Markdown 与代码块支持。",
    heroImage: "/docs/screenshots/transcript-search.png",
    heroImageAlt: "Claude Statistics 中的 transcript 搜索界面,工具调用分类显示",
    hubKicker: "01 · Sessions",
    hubTitle: "搜遍你已经拥有的每一份 transcript。",
    hubBlurb:
      "折叠的会话列表、工具感知的 transcript 查看器、⌘F 全文搜索,hover 菜单一键回到准确的项目上下文。",
    hubBullets: [
      "按工作目录分组,模型徽章和 Token 数实时可见",
      "工具调用分色渲染,Markdown 与代码块高亮",
      "基于 SQLite FTS 的全库搜索,带 snippet 命中"
    ],
    capabilities: [
      {
        num: "01",
        title: "项目折叠的会话列表",
        text:
          "按工作目录分组。Hover 即出 resume、复制路径、删除、批量删除。在 provider 格式允许时支持实时文件监听。"
      },
      {
        num: "02",
        title: "工具感知的 Transcript 查看器",
        text:
          "User、Assistant 和每个工具调用各自有色。Markdown 正确渲染,代码块高亮,搜索匹配跳转时滚动位置不丢。"
      },
      {
        num: "03",
        title: "全归档搜索",
        text:
          "⌘F 跨 provider 搜索每份 transcript 的完整正文,使用 SQLite FTS5。结果显示项目、时间和命中片段。"
      }
    ],
    howItWorks: {
      title: "工作原理",
      intro:
        "Claude Statistics 在本地索引 transcript 文件 — 不上传,不依赖远端服务。文件监听确保新增的 turn 立即进入索引。",
      steps: [
        {
          heading: "本地发现",
          text:
            "启动时遍历 ~/.claude、~/.codex 和 ~/.gemini,之后通过 FSEvents 持续监听变化。"
        },
        {
          heading: "JSONL 解析",
          text:
            "每个 turn 解析一次并缓存。Codex 的 WAL/SHM sidecar 在解析前会被合并,确保活跃会话仍可读。"
        },
        {
          heading: "FTS 索引",
          text:
            "片段匹配使用 SQLite FTS5。一次查询即可返回跨所有 provider 的排序命中结果。"
        }
      ]
    },
    scenarios: {
      title: "什么时候最有用",
      items: [
        {
          title: "找回上个月用过的 prompt",
          text:
            "搜索 'pricing migration',Claude Statistics 会列出每个出现这条线索的项目,包含时间戳和命中上下文。"
        },
        {
          title: "审计哪个工具在何时跑过",
          text:
            "工具感知配色一眼看出某次修复用的是 Edit、Bash、MultiEdit 还是 apply_patch — 跨三种 CLI 都成立。"
        }
      ]
    },
    related: ["analytics", "notch-island", "accounts"]
  },
  analytics: {
    slug: "analytics",
    eyebrow: "02 · 全时段分析",
    title: "53 周热力图、每日节律、真实成本信号。",
    lede:
      "全时段、日、周、月多维度统计,跨 Claude Code、Codex CLI、Gemini CLI 聚合。项目按成本排名、双 Y 轴趋势图、模型与缓存分布。",
    heroImage: "/docs/screenshots/statistics-overview.png",
    heroImageAlt: "53 周热力图、KPI 概览卡片与趋势图组成的统计总览",
    hubKicker: "02 · Analytics",
    hubTitle: "看清每周、每月与每次爆发期的形状。",
    hubBlurb:
      "热力图、KPI 卡片、项目排名、趋势图、模型分布 — 全部基于本地 transcript 生成。",
    hubBullets: [
      "53 周 GitHub 风格热力图,品红高强度区域",
      "项目按成本排名,Token 总量与趋势可下钻",
      "成本按模型拆分,缓存读写比与上下文压力"
    ],
    capabilities: [
      {
        num: "01",
        title: "反映真实使用的热力图",
        text:
          "热度按 Token 吞吐校准,而不是会话数,所以 5 分钟的爆发和深度工作日不会长得一样。"
      },
      {
        num: "02",
        title: "周期下钻",
        text:
          "在 All / Daily / Weekly / Monthly 之间切换无需重算。点击任意项目展开同周期下的双 Y 轴趋势。"
      },
      {
        num: "03",
        title: "成本优先排名",
        text:
          "项目按花费排序,而不是活跃度。每行的成本、Token 总量与模型拆分会告诉你预算到底花在哪。"
      }
    ],
    howItWorks: {
      title: "工作原理",
      intro:
        "成本按模型从可编辑的定价表算出。Cache 读写独立追踪,使总数与 provider 实际计费一致。",
      steps: [
        {
          heading: "定价表",
          text:
            "内置定价表覆盖 Anthropic、OpenAI、Google 模型。新模型上线或调价时可手工覆盖。"
        },
        {
          heading: "本地聚合",
          text:
            "聚合按日、周、月、项目滚动 — 新 turn 落地即增量重算。"
        },
        {
          heading: "跨 provider 计算",
          text:
            "Token 总量按 provider 分别保存,即使某个 CLI 改变记账方式,跨 provider 图表仍有意义。"
        }
      ]
    },
    scenarios: {
      title: "什么时候最有用",
      items: [
        {
          title: "周末预算盘点",
          text:
            "周五打开 Stats tab,热力图、项目排名、模型拆分让你立刻看出本周是不是踩在计划内。"
        },
        {
          title: "诚实地比较两个项目",
          text:
            "在同周期下钻项目 A 和 B;双 Y 轴图同时显示 Token 与成本,你能立刻看出哪个用了更便宜的模型。"
        }
      ]
    },
    related: ["usage", "sessions", "share"]
  },
  usage: {
    slug: "usage",
    eyebrow: "03 · 配额与订阅窗口",
    title: "重置之前就知道你会不会撞顶。",
    lede:
      "追踪 Claude 的 5h / 7d / per-model 窗口,Codex 的 5h 与周窗口,Gemini 的 Pro / Flash / Flash-Lite 分组配额。绿 → 黄 → 红,一眼可读。",
    heroImage: "/docs/screenshots/usage-hover.png",
    heroImageAlt: "配额窗口、倒计时与分组 quota buckets",
    hubKicker: "03 · Usage",
    hubTitle: "订阅窗口 · 重置倒计时 · 按 provider 分。",
    hubBlurb:
      "Claude、Codex、Gemini 的实时配额压力。能拉官方 API 就拉,拉不到就在本地算。",
    hubBullets: [
      "Claude 5h / 7d / 7d-Sonnet 窗口来自 OAuth API",
      "Codex 5h 与周窗口从本地 JWT 重建",
      "Gemini 分组 quota,基于重置时间锚定的趋势"
    ],
    capabilities: [
      {
        num: "01",
        title: "Provider 感知的窗口",
        text:
          "每个 CLI 的配额模型不同。Claude Statistics 用各自原生形态展示,而不是合并成一个伪统一视图。"
      },
      {
        num: "02",
        title: "重置锚定的趋势",
        text:
          "趋势图按 provider 定义的边界重置(5h 滑动窗、周一周窗、UTC 日窗),新窗口从零开始,不会拼上昨天的尾巴。"
      },
      {
        num: "03",
        title: "菜单栏一眼可读",
        text:
          "接近 70% 时图标变黄,超过 90% 变红,在工作流停摆前你就能看到压力。"
      }
    ],
    howItWorks: {
      title: "工作原理",
      intro:
        "已认证状态下从 provider 官方 endpoint 拉配额,与本地 Token 计数合并,使数字与 CLI 看到的一致。",
      steps: [
        {
          heading: "Claude — OAuth",
          text:
            "Anthropic OAuth API 返回 5h、7d 与 per-model 用量。按可配置频率刷新,聚焦时也会刷新。"
        },
        {
          heading: "Codex — 本地 JWT",
          text:
            "Codex CLI 把 plan 信息编进 JWT;我们在本地解码 plan tier,再与 transcript 活动重建用量。"
        },
        {
          heading: "Gemini — 分组 buckets",
          text:
            "Pro / Flash / Flash-Lite 各自独立追踪,带各自的重置时间。"
        }
      ]
    },
    scenarios: {
      title: "什么时候最有用",
      items: [
        {
          title: "工作流途中查窗口",
          text:
            "瞥一眼菜单栏;红了说明你只剩几分钟,可以把后续工作切到另一个 provider。"
        },
        {
          title: "周末规划",
          text:
            "周六看一眼 7d Sonnet 窗口,告诉你今天能不能花一整天做深度重构,还是会在 deadline 前撞顶。"
        }
      ]
    },
    related: ["analytics", "accounts", "notch-island"]
  },
  "notch-island": {
    slug: "notch-island",
    eyebrow: "04 · 刘海岛",
    title: "停驻在 MacBook 刘海区的实时活动面板。",
    lede:
      "平时只是一条黑色刘海 — 完全透明于你的工作流。Claude Code、Codex、Gemini 有事情发生时(等待、工作中、等待审批),它才弹出来。Return 一键跳回会话所在的精确终端 tab。",
    heroImage: "/notch-island.png",
    heroImageAlt: "刘海岛展示活动会话、权限卡片与任务完成状态",
    hubKicker: "04 · Notch Island",
    hubTitle: "你已经在看的地方,放上实时会话状态。",
    hubBlurb:
      "活动会话列表、内联权限卡片、一键跳回 — 全部发生在 MacBook 刘海区。",
    hubBullets: [
      "在跑会话按项目分组,实时状态可见",
      "Claude 权限请求以 Allow / Deny 卡片内联弹出",
      "Tab 级精确跳转 Ghostty / iTerm2 / Terminal"
    ],
    capabilities: [
      {
        num: "01",
        title: "活动会话列表",
        text:
          "所有在跑会话按项目分组,实时状态:等待输入 / 工作中 / 等待审批。Hook 触发时实时更新。"
      },
      {
        num: "02",
        title: "内联权限卡片",
        text:
          "Claude Code 权限请求以 Allow / Deny 卡片弹出。决定通过 hook 协议回写 — 全程不切终端。"
      },
      {
        num: "03",
        title: "Tab 级精确跳转",
        text:
          "点击卡片或按 Return 跳转到会话所在的精确终端 tab — Ghostty surface id、iTerm2 tty、Terminal tab 全支持。"
      }
    ],
    howItWorks: {
      title: "工作原理",
      intro:
        "刘海岛完全由 hook 驱动。Claude Statistics 把 hook 安装到 ~/.claude/settings.json、~/.codex/hooks.json 与 ~/.gemini/settings.json — 事件以 JSON 形式从 stdin 回流。",
      steps: [
        {
          heading: "Hook 事件",
          text:
            "PreToolUse、PostToolUse、Notification、Stop、PermissionRequest 等 — 每条事件携带 session id、项目路径与对应工具调用。"
        },
        {
          heading: "状态聚合",
          text:
            "应用把原始事件折叠成会话视图:等待用户、工作中、等待审批、空闲、完成。"
        },
        {
          heading: "审批往返",
          text:
            "Allow / Deny 一点会通过 hook stdin 协议写回 JSON 决定,Claude 立即继续。"
        }
      ]
    },
    scenarios: {
      title: "什么时候最有用",
      items: [
        {
          title: "并行跑三个会话",
          text:
            "会话 A 要审批时,刘海亮起带命令;一点放行,你继续在会话 B。"
        },
        {
          title: "走开一会儿再回来",
          text:
            "去趟厨房,远远瞥一眼 — 绿点表示在等你,黄点表示还在工作。"
        }
      ]
    },
    related: ["sessions", "accounts", "usage"]
  },
  accounts: {
    slug: "accounts",
    eyebrow: "05 · 账号与 CLI 身份",
    title: "切换的是 CLI 账号本身,不是一个标签。",
    lede:
      "Claude Statistics 为 Claude、Codex、Gemini 维护托管账号;选择另一个身份时,真正切换 CLI 当前生效的 live account。",
    heroImage: "/docs/screenshots/hero-overview.png",
    heroImageAlt: "Provider 上下文与托管账号列表、切换控件",
    hubKicker: "05 · Accounts",
    hubTitle: "Provider 切换与账号切换,刻意分开。",
    hubBlurb:
      "在 Settings 添加 provider 账号,在同一面板切换激活的 CLI 身份 — 不需手改认证文件。",
    hubBullets: [
      "添加新 provider 账号无需手改 dotfiles",
      "应用内切换 Claude / Codex / Gemini 当前激活身份",
      "Provider home 与账号状态彼此独立,可分别调整"
    ],
    capabilities: [
      {
        num: "01",
        title: "托管账号列表",
        text:
          "你添加过的每个 Claude、Codex、Gemini 账号显示为一行,带当前状态与一键切换。认证文件原子写入。"
      },
      {
        num: "02",
        title: "实时身份切换",
        text:
          "切换身份会重写 CLI 读取的活跃 token / refresh credential — 下次 claude / codex / gemini 调用就以新用户身份运行。"
      },
      {
        num: "03",
        title: "与 provider 切换独立",
        text:
          "菜单栏切换 provider home 是一个轴;切换 CLI 身份是另一个轴。两者不会冲撞。"
      }
    ],
    howItWorks: {
      title: "工作原理",
      intro:
        "每个 provider 的认证布局不同 — Claude 的 OAuth 文件、Codex 的 JWT、Gemini 的 settings。应用以托管账号模型抽象这些差异。",
      steps: [
        {
          heading: "捕获",
          text:
            "登录 CLI 时,应用把认证文件捕获为托管快照。"
        },
        {
          heading: "激活",
          text:
            "选择已保存账号会把对应 credential 原子写入 CLI 读取的实际路径。"
        },
        {
          heading: "验证",
          text:
            "激活后菜单栏刷新身份徽章,可以确认切换生效。"
        }
      ]
    },
    scenarios: {
      title: "什么时候最有用",
      items: [
        {
          title: "个人 vs 工作 Claude",
          text:
            "一键从个人 Max 账号切到团队账号 — 不丢失个人账号,也不用手抄 token。"
        },
        {
          title: "对照测试不同 Codex 套餐",
          text:
            "Plus 与 Pro 同时保留;开始长任务前切到配额窗口最干净的那个。"
        }
      ]
    },
    related: ["usage", "sessions", "notch-island"]
  },
  share: {
    slug: "share",
    eyebrow: "06 · 分享卡 与 角色",
    title: "把高强度使用历史变成别人会记住的身份卡。",
    lede:
      "Share Preview 把角色标签、徽章解锁、成本与 Token 证据、项目覆盖度、可扫码版式组合成一张值得分享的卡片。",
    heroImage: null,
    heroImageAlt: "分享卡角色与徽章合成预览",
    hubKicker: "06 · Share",
    hubTitle: "基于真实历史的精致、可证明的卡片。",
    hubBlurb:
      "9 种角色原型、11 个可解锁徽章,原生分辨率 PNG 导出,内置二维码。",
    hubBullets: [
      "9 种角色基于你的实际使用模式自动派生",
      "11 个徽章按真实活动阈值解锁",
      "原生 PNG 导出 + 复制 / 保存 / 社交分享"
    ],
    capabilities: [
      {
        num: "01",
        title: "9 种角色原型",
        text:
          "冲刺型黑客、上下文驯兽师、效率操盘手、夜行工程师、多模型导演、稳健建造者、工具召唤师、全栈开荒者、Vibe Coding 之王。"
      },
      {
        num: "02",
        title: "11 个可解锁徽章",
        text:
          "吞吐猛兽、缓存法师、成本克制派、项目跳跃者等 — 根据具体阈值解锁,不是随手发的奖章。"
      },
      {
        num: "03",
        title: "生产级导出",
        text:
          "原生分辨率 PNG,内嵌二维码,可直接发 Twitter、LinkedIn 或团队群。无水印、不上传。"
      }
    ],
    howItWorks: {
      title: "工作原理",
      intro:
        "角色与徽章基于真实 transcript 评分。整个合成过程在本地完成 — 不上传任何数据。",
      steps: [
        {
          heading: "评分",
          text:
            "每个角色有一个数值标准(平均上下文比、夜间 Token 占比、跨项目数),从本地数据计算。"
        },
        {
          heading: "匹配",
          text:
            "前三高的角色以匹配百分比展示,卡片可以诚实地标出主要身份与次要候选。"
        },
        {
          heading: "渲染",
          text:
            "海报以原生分辨率绘制,使用应用同款渲染引擎,导出为 PNG。"
        }
      ]
    },
    scenarios: {
      title: "什么时候最有用",
      items: [
        {
          title: "年度回顾",
          text:
            "高强度季度后生成一张;Token、成本、活跃天数让信息流里的人多停留三次。"
        },
        {
          title: "团队身份",
          text:
            "每个工程师的卡都不同,因为底层是真实使用模式 — 不是统一模板。"
        }
      ]
    },
    related: ["analytics", "sessions", "usage"]
  }
};

export const featureContent: Record<Language, Record<FeatureSlug, FeatureDetail>> = {
  en,
  zh
};

export const featureHubCopy = {
  en: {
    eyebrow: "Features",
    title: "Six surfaces — every one designed around a real workflow.",
    lede:
      "Claude Statistics is six tightly scoped surfaces sharing one local index. Pick one to dive deeper.",
    learnMore: "Learn more",
    related: "Related features"
  },
  zh: {
    eyebrow: "功能",
    title: "六个面 — 每一个都围绕一个真实工作流设计。",
    lede:
      "Claude Statistics 是六个紧凑功能面共享一份本地索引。挑一个深入了解。",
    learnMore: "查看详情",
    related: "相关功能"
  }
} as const;
