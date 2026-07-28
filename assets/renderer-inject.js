(() => {
  const CSS_TEXT = __DOUBAO_SKIN_CSS_JSON__;
  const ART_SOURCE = __DOUBAO_SKIN_ART_JSON__;
  const THEME = __DOUBAO_SKIN_THEME_JSON__;
  const SELECTORS = __DOUBAO_SKIN_SELECTORS_JSON__;
  const VERSION = __DOUBAO_SKIN_VERSION_JSON__;
  const REVISION = __DOUBAO_SKIN_REVISION_JSON__;

  const STATE_KEY = "__DOUBAO_SKIN_POC_RUNTIME__";
  const STYLE_REGISTRY_KEY = "__DOUBAO_SKIN_POC_STYLE_SHEETS__";
  const STYLE_ID = "doubao-skin-poc-style";
  const DECORATION_ID = "doubao-skin-poc-decoration";
  const ROOT_ATTRIBUTE = "data-doubao-skin";
  const THEME_ATTRIBUTE = "data-doubao-skin-theme";
  const ART_ATTRIBUTE = "data-doubao-skin-has-art";
  const ROOT_PROPERTIES = [
    "--doubao-skin-accent",
    "--doubao-skin-accent-soft",
    "--doubao-skin-cyan",
    "--doubao-skin-pink",
    "--doubao-skin-text",
    "--doubao-skin-muted",
    "--doubao-skin-panel",
    "--doubao-skin-panel-strong",
    "--doubao-skin-line",
    "--doubao-skin-conversation-scrim",
    "--doubao-skin-menu-background",
    "--doubao-skin-text-primary",
    "--doubao-skin-text-secondary",
    "--doubao-skin-text-muted",
    "--doubao-skin-text-subtle",
    "--doubao-skin-text-disabled",
    "--doubao-skin-text-heading",
    "--doubao-skin-text-sidebar",
    "--doubao-skin-text-sidebar-muted",
    "--doubao-skin-text-suggestion",
    "--doubao-skin-text-action",
    "--doubao-skin-text-link",
    "--doubao-skin-composer-text",
    "--doubao-skin-composer-placeholder",
    "--doubao-skin-composer-toolbar",
    "--doubao-skin-composer-icon-filter",
    "--doubao-skin-composer-background",
    "--doubao-skin-composer-background-accent",
    "--doubao-skin-composer-border",
    "--doubao-skin-background-image",
  ];

  const existing = window[STATE_KEY];
  if (existing?.revision === REVISION && typeof existing.ensure === "function") {
    existing.ensure();
    return existing.status();
  }
  if (existing?.cleanup) {
    try {
      existing.cleanup();
    } catch {}
  }

  let artObjectUrl = null;
  const ART_URL = (() => {
    if (!ART_SOURCE?.base64 || !ART_SOURCE?.mime) return null;
    const binary = atob(ART_SOURCE.base64);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    artObjectUrl = URL.createObjectURL(new Blob([bytes], { type: ART_SOURCE.mime }));
    return artObjectUrl;
  })();

  const root = document.documentElement;
  if (!root) {
    return {
      installed: false,
      reason: "documentElement is unavailable",
      revision: REVISION,
      version: VERSION,
    };
  }

  const styleRegistry = window[STYLE_REGISTRY_KEY] instanceof Set
    ? window[STYLE_REGISTRY_KEY]
    : new Set();
  window[STYLE_REGISTRY_KEY] = styleRegistry;

  let styleMode = "none";
  let styleNode = null;
  let styleSheet = null;
  let decorationNode = null;
  let observer = null;
  let timer = null;
  let scheduled = null;
  const installToken = `${Date.now()}:${Math.random().toString(36).slice(2)}`;

  const setAttribute = (node, name, value) => {
    if (node.getAttribute(name) !== value) node.setAttribute(name, value);
  };

  const setProperty = (node, name, value) => {
    if (node.style.getPropertyValue(name) !== value) node.style.setProperty(name, value);
  };

  const backgroundImage = ART_URL
    ? [
      "linear-gradient(105deg, rgba(255, 255, 255, 0.18), rgba(255, 255, 255, 0.08) 56%, transparent 82%)",
      `url("${ART_URL}")`,
    ].join(", ")
    : [
      "radial-gradient(circle at 82% 12%, rgba(71, 184, 255, 0.64), transparent 39%)",
      "radial-gradient(circle at 10% 88%, rgba(242, 155, 194, 0.58), transparent 41%)",
      "radial-gradient(circle at 57% 67%, rgba(145, 118, 248, 0.5), transparent 46%)",
      "linear-gradient(135deg, #eee9ff 0%, #def3ff 48%, #ffe6f1 100%)",
    ].join(", ");

  const color = (name, fallback) => {
    const value = THEME?.colors?.[name];
    return typeof value === "string" && value ? value : fallback;
  };

  const componentColor = (component, name, fallback) => {
    const value = THEME?.[component]?.[name];
    return typeof value === "string" && value ? value : fallback;
  };

  const applyRoot = () => {
    setAttribute(root, ROOT_ATTRIBUTE, "active");
    setAttribute(root, THEME_ATTRIBUTE, String(THEME?.id || "custom"));
    setAttribute(root, ART_ATTRIBUTE, ART_URL ? "true" : "false");
    setProperty(root, "--doubao-skin-accent", color("accent", "#6d5dfc"));
    setProperty(root, "--doubao-skin-accent-soft", color("accentSoft", "#a78bfa"));
    setProperty(root, "--doubao-skin-cyan", color("cyan", "#47b8ff"));
    setProperty(root, "--doubao-skin-pink", color("pink", "#f29bc2"));
    setProperty(root, "--doubao-skin-text", color("text", "#252338"));
    setProperty(root, "--doubao-skin-muted", color("muted", "#6d6981"));
    setProperty(root, "--doubao-skin-panel", color("panel", "rgba(255, 255, 255, 0.64)"));
    setProperty(
      root,
      "--doubao-skin-panel-strong",
      color("panelStrong", "rgba(255, 255, 255, 0.84)"),
    );
    setProperty(root, "--doubao-skin-line", color("line", "rgba(79, 70, 130, 0.13)"));
    setProperty(
      root,
      "--doubao-skin-conversation-scrim",
      componentColor(
        "surfaces",
        "conversation",
        color("panelStrong", "rgba(255, 255, 255, 0.66)"),
      ),
    );
    setProperty(
      root,
      "--doubao-skin-menu-background",
      componentColor(
        "surfaces",
        "menu",
        color("panelStrong", "rgba(255, 255, 255, 0.94)"),
      ),
    );
    setProperty(
      root,
      "--doubao-skin-text-primary",
      componentColor("typography", "primary", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-text-secondary",
      componentColor("typography", "secondary", color("muted", "#6d6981")),
    );
    setProperty(
      root,
      "--doubao-skin-text-muted",
      componentColor("typography", "muted", color("muted", "#6d6981")),
    );
    setProperty(
      root,
      "--doubao-skin-text-subtle",
      componentColor("typography", "subtle", "rgba(109, 105, 129, 0.58)"),
    );
    setProperty(
      root,
      "--doubao-skin-text-disabled",
      componentColor("typography", "disabled", "rgba(109, 105, 129, 0.36)"),
    );
    setProperty(
      root,
      "--doubao-skin-text-heading",
      componentColor("typography", "heading", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-text-sidebar",
      componentColor("typography", "sidebar", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-text-sidebar-muted",
      componentColor("typography", "sidebarMuted", color("muted", "#6d6981")),
    );
    setProperty(
      root,
      "--doubao-skin-text-suggestion",
      componentColor("typography", "suggestion", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-text-action",
      componentColor("typography", "action", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-text-link",
      componentColor("typography", "link", color("accent", "#6d5dfc")),
    );
    setProperty(
      root,
      "--doubao-skin-composer-text",
      componentColor("composer", "text", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-composer-placeholder",
      componentColor("composer", "placeholder", color("muted", "#6d6981")),
    );
    setProperty(
      root,
      "--doubao-skin-composer-toolbar",
      componentColor("composer", "toolbar", color("text", "#252338")),
    );
    setProperty(
      root,
      "--doubao-skin-composer-icon-filter",
      componentColor(
        "composer",
        "iconFilter",
        "brightness(0%) saturate(100%) invert(16%) sepia(56%) saturate(3503%) "
          + "hue-rotate(-121deg) brightness(22%) contrast(79%)",
      ),
    );
    setProperty(
      root,
      "--doubao-skin-composer-background",
      componentColor(
        "composer",
        "background",
        color("panelStrong", "rgba(255, 255, 255, 0.58)"),
      ),
    );
    setProperty(
      root,
      "--doubao-skin-composer-background-accent",
      componentColor(
        "composer",
        "backgroundAccent",
        color("panel", "rgba(255, 255, 255, 0.58)"),
      ),
    );
    setProperty(
      root,
      "--doubao-skin-composer-border",
      componentColor("composer", "border", color("line", "rgba(79, 70, 130, 0.13)")),
    );
    setProperty(root, "--doubao-skin-background-image", backgroundImage);
  };

  const installStyle = () => {
    try {
      if (!("adoptedStyleSheets" in document) || typeof CSSStyleSheet !== "function") {
        throw new Error("Constructable stylesheets are unavailable");
      }
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(CSS_TEXT);
      const retained = [...document.adoptedStyleSheets]
        .filter((candidate) => !styleRegistry.has(candidate));
      document.adoptedStyleSheets = [...retained, sheet];
      styleRegistry.clear();
      styleRegistry.add(sheet);
      document.getElementById(STYLE_ID)?.remove();
      styleSheet = sheet;
      styleMode = "adopted";
      return;
    } catch {
      styleSheet = null;
    }

    styleNode = document.getElementById(STYLE_ID) || document.createElement("style");
    styleNode.id = STYLE_ID;
    styleNode.textContent = CSS_TEXT;
    if (!styleNode.parentElement) {
      (document.head || document.documentElement).appendChild(styleNode);
    }
    styleMode = "style";
  };

  const ensureStyle = () => {
    if (styleMode === "adopted" && styleSheet) {
      const current = [...document.adoptedStyleSheets];
      if (!current.includes(styleSheet)) {
        document.adoptedStyleSheets = [...current, styleSheet];
      }
      return;
    }
    if (styleMode === "style" && styleNode && document.getElementById(STYLE_ID) !== styleNode) {
      document.getElementById(STYLE_ID)?.remove();
      (document.head || document.documentElement).appendChild(styleNode);
    }
  };

  const createDecoration = () => {
    const decoration = THEME?.decoration;
    if (!decoration?.title) return null;
    document.getElementById(DECORATION_ID)?.remove();
    const node = document.createElement("aside");
    node.id = DECORATION_ID;
    node.setAttribute("aria-hidden", "true");
    node.setAttribute("data-doubao-skin-decoration", String(THEME?.id || "custom"));

    const title = document.createElement("span");
    title.className = "doubao-skin-decoration-title";
    title.textContent = decoration.title;
    node.appendChild(title);

    if (decoration.subtitle) {
      const subtitle = document.createElement("span");
      subtitle.className = "doubao-skin-decoration-subtitle";
      subtitle.textContent = decoration.subtitle;
      node.appendChild(subtitle);
    }

    if (Array.isArray(decoration.lines) && decoration.lines.length) {
      const list = document.createElement("span");
      list.className = "doubao-skin-decoration-lines";
      for (const value of decoration.lines) {
        const line = document.createElement("span");
        line.textContent = value;
        list.appendChild(line);
      }
      node.appendChild(list);
    }
    return node;
  };

  const ensureDecoration = () => {
    if (!THEME?.decoration?.title) {
      document.getElementById(DECORATION_ID)?.remove();
      decorationNode = null;
      return;
    }
    if (!decorationNode) decorationNode = createDecoration();
    if (decorationNode && document.body && !decorationNode.isConnected) {
      document.body.appendChild(decorationNode);
    }
  };

  const markerSnapshot = () => Object.fromEntries(
    SELECTORS.selectors.map((entry) => {
      try {
        return [entry.key, Boolean(document.querySelector(entry.selector))];
      } catch {
        return [entry.key, false];
      }
    }),
  );

  const ensure = () => {
    if (window[STATE_KEY]?.installToken !== installToken) return false;
    ensureStyle();
    applyRoot();
    ensureDecoration();
    return true;
  };

  const status = () => {
    const markers = markerSnapshot();
    const required = SELECTORS.selectors.filter((entry) => entry.required);
    const shellSelector = SELECTORS.selectors.find((entry) => entry.key === "shell")?.selector;
    const shell = shellSelector ? document.querySelector(shellSelector) : null;
    const shellStyle = shell ? getComputedStyle(shell) : null;
    const composer = document.querySelector('[data-testid="chat_input"]');
    const composerSurface = composer?.querySelector(
      ':scope > [class*="input-guidance-input-container-background"]',
    );
    const composerInput = document.querySelector('[data-testid="chat_input_input"]');
    const composerButton = composer?.querySelector('button, [role="button"]');
    const composerStyle = composer ? getComputedStyle(composer) : null;
    const composerSurfaceStyle = composerSurface ? getComputedStyle(composerSurface) : null;
    const composerInputStyle = composerInput ? getComputedStyle(composerInput) : null;
    const composerPlaceholderStyle = composerInput
      ? getComputedStyle(composerInput, "::placeholder")
      : null;
    const composerButtonStyle = composerButton ? getComputedStyle(composerButton) : null;
    const rootComputedStyle = getComputedStyle(root);
    const messageList = document.querySelector('[data-testid="message-list"]');
    const conversationSurface = messageList?.closest("main");
    const conversationSurfaceStyle = conversationSurface
      ? getComputedStyle(conversationSurface)
      : null;
    const conversationBottomFade = conversationSurface?.querySelector(
      '[class*="from-s-color-bg-body"]',
    );
    const conversationBottomFadeStyle = conversationBottomFade
      ? getComputedStyle(conversationBottomFade)
      : null;
    const sampleTextColor = (selector) => {
      try {
        const node = document.querySelector(selector);
        return node ? getComputedStyle(node).color : "missing";
      } catch {
        return "invalid-selector";
      }
    };
    const visibleTextColorCounts = {};
    for (const node of shell?.querySelectorAll(
      'span, p, a, button, input, textarea, [contenteditable="true"]',
    ) || []) {
      const box = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      if (
        box.width < 1
        || box.height < 1
        || style.display === "none"
        || style.visibility === "hidden"
        || Number(style.opacity) === 0
        || node.getAttribute("role") === "img"
        || (
          !["INPUT", "TEXTAREA"].includes(node.tagName)
          && !node.textContent?.trim()
        )
      ) {
        continue;
      }
      visibleTextColorCounts[style.color] = (visibleTextColorCounts[style.color] || 0) + 1;
    }
    const nativeBlackTextCount = Object.entries(visibleTextColorCounts)
      .filter(([value]) => (
        value === "rgb(0, 0, 0)"
        || value.startsWith("rgba(0, 0, 0,")
      ))
      .reduce((total, [, count]) => total + count, 0);
    const isVisible = (node) => {
      const box = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return (
        box.width >= 1
        && box.height >= 1
        && style.display !== "none"
        && style.visibility !== "hidden"
        && Number(style.opacity) !== 0
      );
    };
    const isNativeBlack = (value) => (
      value === "rgb(0, 0, 0)"
      || value.startsWith("rgba(0, 0, 0,")
    );
    const isTransparentSurface = (style) => Boolean(
      style
      && style.backgroundImage === "none"
      && ["rgba(0, 0, 0, 0)", "transparent"].includes(style.backgroundColor),
    );
    const visibleVectorPaintsFor = (container, excludeOverlays = false) => [
      ...container?.querySelectorAll(
        "svg :where(path, circle, ellipse, line, polygon, polyline, rect, use)",
      ) || [],
    ]
      .filter((node) => (
        !excludeOverlays
        || !node.closest('[role="menu"], [role="dialog"]')
      ))
      .filter((node) => isVisible(node.ownerSVGElement || node))
      .map((node) => {
        const style = getComputedStyle(node);
        const paints = [];
        if (style.fill !== "none" && Number(style.fillOpacity) !== 0) paints.push(style.fill);
        if (style.stroke !== "none" && Number(style.strokeOpacity) !== 0) {
          paints.push(style.stroke);
        }
        return paints;
      })
      .flat();
    const visibleVectorPaints = visibleVectorPaintsFor(composer, true);
    const nativeBlackVectorPaintCount = visibleVectorPaints.filter(isNativeBlack).length;
    const visibleRasterIcons = [
      ...composer?.querySelectorAll("img") || [],
    ]
      .filter((node) => !node.closest('[role="menu"], [role="dialog"]'))
      .filter(isVisible)
      .filter((node) => {
        const box = node.getBoundingClientRect();
        return box.width <= 24 && box.height <= 24;
      })
      .map((node) => {
        const validButton = node.closest("[data-valid-btn]")?.getAttribute("data-valid-btn");
        const testid = node.closest("[data-testid]")?.getAttribute("data-testid");
        return {
          anchor: validButton
            ? `[data-valid-btn="${validButton}"]`
            : testid
              ? `[data-testid="${testid}"]`
              : "unanchored-composer-image",
          filter: getComputedStyle(node).filter,
        };
      });
    const untintedRasterIconCount = visibleRasterIcons
      .filter((entry) => !entry.filter || entry.filter === "none")
      .length;
    const composerActionButtons = [
      ...composer?.querySelectorAll('button[data-testid^="skill_bar_button_"]') || [],
    ]
      .filter((node) => !node.closest('[role="menu"], [role="dialog"]'))
      .filter(isVisible)
      .map((node) => {
        const style = getComputedStyle(node);
        return {
          anchor: `[data-testid="${node.getAttribute("data-testid") || "missing"}"]`,
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          interactive: node.matches(":hover, [data-highlighted]"),
          transparent: isTransparentSurface(style),
        };
      });
    const unexpectedFilledComposerActionButtonCount = composerActionButtons
      .filter((entry) => !entry.interactive && !entry.transparent)
      .length;
    const modeMenu = [...document.querySelectorAll('[role="menu"]')]
      .find((node) => (
        isVisible(node)
        && node.querySelector('img[src*="/mode_fast.png"]')
      ));
    const modeMenuStyle = modeMenu ? getComputedStyle(modeMenu) : null;
    const visibleModeMenuRasterIcons = [
      ...modeMenu?.querySelectorAll("img") || [],
    ]
      .filter(isVisible)
      .filter((node) => {
        const box = node.getBoundingClientRect();
        return box.width >= 14 && box.width <= 24 && box.height >= 14 && box.height <= 24;
      })
      .map((node, index) => ({
        filter: getComputedStyle(node).filter,
        index,
      }));
    const modeMenuVectorPaints = visibleVectorPaintsFor(modeMenu);
    const nativeBlackModeMenuVectorPaintCount =
      modeMenuVectorPaints.filter(isNativeBlack).length;
    const untintedModeMenuRasterIconCount = visibleModeMenuRasterIcons
      .filter((entry) => !entry.filter || entry.filter === "none")
      .length;
    const moreMenu = [...document.querySelectorAll('[role="dialog"]')]
      .find((node) => (
        isVisible(node)
        && node.querySelector(
          '[data-input-engine-action-source="actionbar"]'
            + '[data-testid="skill_bar_button_1005"]',
        )
        && node.querySelector(
          '[data-input-engine-action-source="actionbar"]'
            + '[data-testid="skill_bar_button_9"]',
        )
        && node.querySelector(
          '[data-input-engine-action-source="actionbar"]'
            + '[data-testid="skill_bar_button_11"]',
        )
      ));
    const moreMenuStyle = moreMenu ? getComputedStyle(moreMenu) : null;
    const moreMenuItems = [
      ...moreMenu?.querySelectorAll('[data-input-engine-action-source="actionbar"]') || [],
    ]
      .filter(isVisible)
      .map((node) => {
        const style = getComputedStyle(node);
        return {
          anchor: `[data-testid="${node.getAttribute("data-testid") || "missing"}"]`,
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          interactive: node.matches(":hover, [data-highlighted]"),
          transparent: isTransparentSurface(style),
        };
      });
    const unexpectedFilledMoreMenuItemCount = moreMenuItems
      .filter((entry) => !entry.interactive && !entry.transparent)
      .length;
    const visibleMoreMenuRasterIcons = [
      ...moreMenu?.querySelectorAll("img") || [],
    ]
      .filter(isVisible)
      .filter((node) => {
        const box = node.getBoundingClientRect();
        return box.width <= 24 && box.height <= 24;
      })
      .map((node, index) => ({
        filter: getComputedStyle(node).filter,
        index,
      }));
    const untintedMoreMenuRasterIconCount = visibleMoreMenuRasterIcons
      .filter((entry) => !entry.filter || entry.filter === "none")
      .length;
    const moreMenuVectorPaints = visibleVectorPaintsFor(moreMenu);
    const nativeBlackMoreMenuVectorPaintCount =
      moreMenuVectorPaints.filter(isNativeBlack).length;
    const viewportArea = Math.max(1, innerWidth * innerHeight);
    const coveringSurfaces = [...document.querySelectorAll("body *")]
      .map((node) => {
        const box = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return {
          area: Math.max(0, box.width) * Math.max(0, box.height),
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          className: typeof node.className === "string" ? node.className.slice(0, 120) : "",
          tag: node.tagName.toLowerCase(),
          testid: node.getAttribute("data-testid") || "",
        };
      })
      .filter((entry) => entry.area >= viewportArea * 0.28 && (
        entry.backgroundImage !== "none"
        || !["rgba(0, 0, 0, 0)", "transparent"].includes(entry.backgroundColor)
      ))
      .sort((left, right) => right.area - left.area)
      .slice(0, 12);
    return {
      installed: root.getAttribute(ROOT_ATTRIBUTE) === "active",
      themeId: THEME?.id || "custom",
      revision: REVISION,
      version: VERSION,
      styleMode,
      stylePresent: styleMode === "adopted"
        ? Boolean(styleSheet && [...document.adoptedStyleSheets].includes(styleSheet))
        : document.getElementById(STYLE_ID) === styleNode,
      decorationPresent: !THEME?.decoration?.title
        || document.getElementById(DECORATION_ID) === decorationNode,
      requiredMarkers: required.map((entry) => entry.key),
      missingRequired: required.filter((entry) => !markers[entry.key]).map((entry) => entry.key),
      markers,
      visual: {
        backgroundImage: shellStyle?.backgroundImage?.slice(0, 320) || "none",
        backgroundPosition: shellStyle?.backgroundPosition || "missing",
        backgroundRepeat: shellStyle?.backgroundRepeat || "missing",
        backgroundSize: shellStyle?.backgroundSize || "missing",
        backgroundVariable: rootComputedStyle
          .getPropertyValue("--doubao-skin-background-image")
          .trim()
          .slice(0, 320),
        shellBackgroundColor: shellStyle?.backgroundColor || "missing",
        composer: {
          backdropFilter: composerStyle?.backdropFilter || "missing",
          backgroundColor: composerStyle?.backgroundColor || "missing",
          backgroundImage: composerStyle?.backgroundImage || "missing",
          borderColor: composerStyle?.borderColor || "missing",
          actionButtons: {
            count: composerActionButtons.length,
            samples: composerActionButtons.slice(0, 12),
            unexpectedFilledCount: unexpectedFilledComposerActionButtonCount,
          },
          nativeInnerSurface: {
            backgroundColor: composerSurfaceStyle?.backgroundColor || "missing",
            backgroundImage: composerSurfaceStyle?.backgroundImage || "missing",
            present: Boolean(composerSurface),
            transparent: isTransparentSurface(composerSurfaceStyle),
          },
          inputColor: composerInputStyle?.color || "missing",
          placeholderColor: composerPlaceholderStyle?.color || "missing",
          toolbarColor: composerButtonStyle?.color || "missing",
          icons: {
            iconFilter: rootComputedStyle
              .getPropertyValue("--doubao-skin-composer-icon-filter").trim() || "missing",
            nativeBlackVectorPaintCount,
            rasterIconCount: visibleRasterIcons.length,
            rasterSamples: visibleRasterIcons.slice(0, 12),
            untintedRasterIconCount,
            vectorPaintCount: visibleVectorPaints.length,
          },
        },
        conversation: {
          active: Boolean(messageList),
          backdropFilter: conversationSurfaceStyle?.backdropFilter || "inactive",
          bottomFadeBackgroundImage:
            conversationBottomFadeStyle?.backgroundImage || "inactive",
          bottomFadePresent: Boolean(conversationBottomFade),
          messageListPresent: Boolean(messageList),
          menuToken: rootComputedStyle
            .getPropertyValue("--doubao-skin-menu-background").trim() || "missing",
          scrimToken: rootComputedStyle
            .getPropertyValue("--doubao-skin-conversation-scrim").trim() || "missing",
          surfaceBackgroundColor:
            conversationSurfaceStyle?.backgroundColor || "inactive",
        },
        modeMenu: {
          backdropFilter: modeMenuStyle?.backdropFilter || "closed",
          backgroundColor: modeMenuStyle?.backgroundColor || "closed",
          backgroundImage: modeMenuStyle?.backgroundImage || "closed",
          nativeBlackVectorPaintCount: nativeBlackModeMenuVectorPaintCount,
          open: Boolean(modeMenu),
          rasterIconCount: visibleModeMenuRasterIcons.length,
          rasterSamples: visibleModeMenuRasterIcons,
          untintedRasterIconCount: untintedModeMenuRasterIconCount,
          vectorPaintCount: modeMenuVectorPaints.length,
        },
        moreMenu: {
          backdropFilter: moreMenuStyle?.backdropFilter || "closed",
          backgroundColor: moreMenuStyle?.backgroundColor || "closed",
          backgroundImage: moreMenuStyle?.backgroundImage || "closed",
          itemCount: moreMenuItems.length,
          itemSamples: moreMenuItems,
          nativeBlackVectorPaintCount: nativeBlackMoreMenuVectorPaintCount,
          open: Boolean(moreMenu),
          rasterIconCount: visibleMoreMenuRasterIcons.length,
          rasterSamples: visibleMoreMenuRasterIcons,
          unexpectedFilledItemCount: unexpectedFilledMoreMenuItemCount,
          untintedRasterIconCount: untintedMoreMenuRasterIconCount,
          vectorPaintCount: moreMenuVectorPaints.length,
        },
        typography: {
          palette: {
            action: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-action").trim() || "missing",
            heading: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-heading").trim() || "missing",
            link: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-link").trim() || "missing",
            muted: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-muted").trim() || "missing",
            primary: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-primary").trim() || "missing",
            sidebar: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-sidebar").trim() || "missing",
            suggestion: rootComputedStyle
              .getPropertyValue("--doubao-skin-text-suggestion").trim() || "missing",
          },
          nativePrimary: rootComputedStyle
            .getPropertyValue("--s-color-text-primary").trim() || "missing",
          nativeBlackTextCount,
          samples: {
            action: sampleTextColor('[data-testid="guidance-skill-bar"] button'),
            conversationTitle: sampleTextColor(
              '[data-testid="editable_conversation_name"]',
            ),
            heading: sampleTextColor('[class*="greeting-text-"]'),
            primary: shellStyle?.color || "missing",
            sidebar: sampleTextColor('[data-testid="flow_chat_sidebar"]'),
            suggestion: sampleTextColor('[data-testid="onboarding_sug_item"]'),
          },
          visibleColorCounts: Object.entries(visibleTextColorCounts)
            .sort((left, right) => right[1] - left[1])
            .slice(0, 16),
        },
        coveringSurfaces,
      },
      href: location.href,
      title: document.title,
    };
  };

  const cleanup = () => {
    const state = window[STATE_KEY];
    if (state?.installToken !== installToken) return false;
    observer?.disconnect();
    if (timer) clearInterval(timer);
    if (scheduled) clearTimeout(scheduled);
    if (styleSheet) {
      try {
        document.adoptedStyleSheets = [...document.adoptedStyleSheets]
          .filter((candidate) => candidate !== styleSheet);
      } catch {}
      styleRegistry.delete(styleSheet);
    }
    styleNode?.remove();
    document.getElementById(STYLE_ID)?.remove();
    decorationNode?.remove();
    document.getElementById(DECORATION_ID)?.remove();
    if (artObjectUrl) {
      try {
        URL.revokeObjectURL(artObjectUrl);
      } catch {}
      artObjectUrl = null;
    }
    root.removeAttribute(ROOT_ATTRIBUTE);
    root.removeAttribute(THEME_ATTRIBUTE);
    root.removeAttribute(ART_ATTRIBUTE);
    for (const property of ROOT_PROPERTIES) root.style.removeProperty(property);
    delete window[STATE_KEY];
    if (styleRegistry.size === 0) delete window[STYLE_REGISTRY_KEY];
    return true;
  };

  installStyle();
  window[STATE_KEY] = {
    cleanup,
    ensure,
    installToken,
    revision: REVISION,
    status,
    version: VERSION,
  };
  ensure();

  if (typeof MutationObserver === "function") {
    observer = new MutationObserver(() => {
      if (scheduled) return;
      scheduled = setTimeout(() => {
        scheduled = null;
        ensure();
      }, 80);
    });
    observer.observe(root, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme", "data-color-mode"],
    });
    window[STATE_KEY].observer = observer;
  }

  timer = setInterval(ensure, 15000);
  window[STATE_KEY].timer = timer;

  return status();
})()
