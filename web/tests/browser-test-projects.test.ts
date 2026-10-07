import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { expect, it } from "vitest";
import type { TestProjectInlineConfiguration } from "vitest/config";

import vitestConfig, { cpuHeavyBrowserTestFiles } from "../vitest.config";

interface BrowserProjectShape {
  readonly name: string;
  readonly include: readonly string[];
  readonly exclude: readonly string[];
  readonly groupOrder: number;
  readonly fileParallelism: boolean;
}

const websiteRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function readBrowserProject(name: string): BrowserProjectShape {
  const project = vitestConfig.test?.projects
    ?.filter(
      (candidate): candidate is TestProjectInlineConfiguration =>
        typeof candidate === "object" && !(candidate instanceof Promise),
    )
    .find((candidate) => candidate.test?.name === name);
  if (project === undefined || project.test === undefined) {
    throw new Error(`Missing Vitest project ${name}`);
  }
  return {
    name,
    include: project.test.include ?? [],
    exclude: project.test.exclude ?? [],
    groupOrder: project.test.sequence?.groupOrder ?? 0,
    fileParallelism: project.test.fileParallelism ?? true,
  };
}

it("runs the CPU-heavy browser files after the parallel group, one file at a time", () => {
  // Arrange
  const parallelProject = readBrowserProject("browser");
  const heavyProject = readBrowserProject("browser-heavy");

  // Act
  const missingHeavyFiles = cpuHeavyBrowserTestFiles.filter(
    (testFile) => !existsSync(path.join(websiteRoot, testFile)),
  );

  // Assert: every heavy file exists, belongs only to the heavy project, and that project
  // starts after the parallel group finishes and runs its files serially.
  expect(missingHeavyFiles).toEqual([]);
  expect(heavyProject.include).toEqual([...cpuHeavyBrowserTestFiles]);
  expect(parallelProject.include).toEqual(["tests/**/*.browser.test.ts"]);
  expect(parallelProject.exclude).toEqual([...cpuHeavyBrowserTestFiles]);
  expect(heavyProject.groupOrder).toBeGreaterThan(parallelProject.groupOrder);
  expect(heavyProject.fileParallelism).toBe(false);
  expect(parallelProject.fileParallelism).toBe(true);
});
