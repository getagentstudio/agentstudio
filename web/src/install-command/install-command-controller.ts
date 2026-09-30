import { marketingCopy } from "../marketing-copy";
import { reduceInstallCommandState, type InstallCommandState } from "./install-command-state";

interface InstallCommandControllerElements {
  readonly button: HTMLButtonElement;
  readonly code: HTMLElement;
  readonly status: HTMLElement;
}

const activeInstallControllers = new WeakMap<HTMLElement, () => void>();

function unexpectedInstallCommandState(state: never): never {
  throw new Error(`Unexpected install command state: ${JSON.stringify(state)}`);
}

function copyStatusText(state: InstallCommandState): string {
  switch (state.kind) {
    case "idle":
      return "";
    case "copied":
      return marketingCopy.installation.copiedStatus;
    case "failed":
      return state.message;
    default:
      return unexpectedInstallCommandState(state);
  }
}

function resolveControllerElements(root: HTMLElement): InstallCommandControllerElements {
  const button = root.querySelector<HTMLButtonElement>("[data-install-copy]");
  const code = root.querySelector<HTMLElement>("[data-install-code]");
  const status = root.querySelector<HTMLElement>("[data-install-status]");

  if (button === null || code === null || status === null) {
    throw new Error("Install command markup is incomplete.");
  }

  return { button, code, status };
}

export function initializeInstallCommand(root: HTMLElement): () => void {
  const existingDispose = activeInstallControllers.get(root);
  if (existingDispose !== undefined) return existingDispose;
  const { button, code, status } = resolveControllerElements(root);
  const lifecycle = new AbortController();
  let state: InstallCommandState = { kind: "idle" };
  let feedbackResetTimer: number | undefined;
  const feedbackLabels = [...root.querySelectorAll<HTMLElement>("[data-install-copy-feedback]")];
  const idleLabels = feedbackLabels.map((label) => label.textContent ?? "");
  const copyIcon = root.querySelector<SVGElement>("[data-install-copy-icon]");
  const copiedIcon = root.querySelector<SVGElement>("[data-install-copied-icon]");
  const renderCopiedIcon = (copied: boolean): void => {
    copyIcon?.toggleAttribute("data-install-icon-hidden", copied);
    copiedIcon?.toggleAttribute("data-install-icon-hidden", !copied);
  };
  const feedbackDurationMs = Number(root.dataset["installFeedbackMs"]);
  const resetFeedback = (): void => {
    feedbackLabels.forEach((label, index) => {
      label.textContent = idleLabels[index] ?? "";
    });
    status.textContent = "";
    renderCopiedIcon(false);
    feedbackResetTimer = undefined;
  };

  const measureCopyLayout = (): void => {
    root.removeAttribute("data-compact-copy");
    const narrowViewport = window.matchMedia("(max-width: 38.749rem)").matches;
    root.toggleAttribute(
      "data-compact-copy",
      narrowViewport || code.scrollWidth > code.clientWidth,
    );
    root.toggleAttribute("data-install-overflow", code.scrollWidth > code.clientWidth);
  };
  const resizeObserver = new ResizeObserver(measureCopyLayout);
  resizeObserver.observe(root);
  window.addEventListener("resize", measureCopyLayout, { signal: lifecycle.signal });
  measureCopyLayout();

  button.addEventListener(
    "click",
    (): void => {
      const command = root.dataset["installCommand"];

      if (command === undefined) {
        state = reduceInstallCommandState(state, {
          kind: "copy-failed",
          message: marketingCopy.installation.failedStatus,
        });
        status.textContent = copyStatusText(state);
        return;
      }

      const clipboard = navigator.clipboard;
      if (clipboard === undefined) {
        state = reduceInstallCommandState(state, {
          kind: "copy-failed",
          message: marketingCopy.installation.failedStatus,
        });
        status.textContent = copyStatusText(state);
        return;
      }

      void clipboard
        .writeText(command)
        .then((): void => {
          state = reduceInstallCommandState(state, { kind: "copy-succeeded" });
          status.textContent = copyStatusText(state);
          renderCopiedIcon(true);
          const copiedLabel = root.dataset["installCopiedLabel"];
          if (copiedLabel !== undefined) {
            for (const label of feedbackLabels) label.textContent = copiedLabel;
          }
          if (feedbackResetTimer !== undefined) window.clearTimeout(feedbackResetTimer);
          if (Number.isFinite(feedbackDurationMs) && feedbackDurationMs > 0) {
            feedbackResetTimer = window.setTimeout(resetFeedback, feedbackDurationMs);
          }
        })
        .catch((): void => {
          state = reduceInstallCommandState(state, {
            kind: "copy-failed",
            message: marketingCopy.installation.failedStatus,
          });
          status.textContent = copyStatusText(state);
        });
    },
    { signal: lifecycle.signal },
  );

  const dispose = (): void => {
    if (feedbackResetTimer !== undefined) window.clearTimeout(feedbackResetTimer);
    resizeObserver.disconnect();
    lifecycle.abort();
    root.removeAttribute("data-install-command-initialized");
    activeInstallControllers.delete(root);
  };
  root.setAttribute("data-install-command-initialized", "");
  activeInstallControllers.set(root, dispose);
  return dispose;
}
