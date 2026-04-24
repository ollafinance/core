#!/usr/bin/env node

import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const args = process.argv.slice(2);
const argMap = new Map();
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith("--")) {
        continue;
    }
    const key = arg.slice(2);
    const value = args[i + 1];
    if (value && !value.startsWith("--")) {
        argMap.set(key, value);
        i += 1;
    } else {
        argMap.set(key, "true");
    }
}

const contractName = argMap.get("contract");
const fixturePath = argMap.get("fixture");
const outputPath = argMap.get("output");
const strict = argMap.get("strict") === "true" || argMap.has("strict");

if (!contractName || !fixturePath) {
    console.error(
        "Usage: node contracts/upgrade/check-storage-layout.ts --contract <Contract> --fixture <fixture.json> [--output <path>] [--strict]"
    );
    process.exit(1);
}

const contractsRoot = path.resolve(__dirname, "..");
const fixtureAbsolute = path.resolve(process.cwd(), fixturePath);
const outputAbsolute = outputPath ? path.resolve(process.cwd(), outputPath) : null;

type StorageLayout = {
    storage?: Array<Record<string, unknown>>;
    types?: Record<string, unknown>;
};

function stableStringify(value: unknown): string {
    if (value === null || typeof value !== "object") {
        return JSON.stringify(value);
    }
    if (Array.isArray(value)) {
        return `[${value.map(stableStringify).join(",")}]`;
    }
    const objectValue = value as Record<string, unknown>;
    const keys = Object.keys(objectValue).sort();
    const entries: string[] = keys.map((key) => `${JSON.stringify(key)}:${stableStringify(objectValue[key])}`);
    return `{${entries.join(",")}}`;
}

function runForgeInspect(contract: string): StorageLayout {
    const output = execSync(`forge inspect ${contract} storage-layout --json`, {
        cwd: contractsRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
    });

    return JSON.parse(output);
}

function diffStorageEntries(
    currentStorage: Array<Record<string, unknown>>,
    fixtureStorage: Array<Record<string, unknown>>,
    differences: string[]
) {
    if (currentStorage.length !== fixtureStorage.length) {
        differences.push(
            `storage length mismatch: expected ${fixtureStorage.length}, got ${currentStorage.length}`
        );
    }

    const compareLength = Math.min(currentStorage.length, fixtureStorage.length);
    for (let i = 0; i < compareLength; i += 1) {
        const currentEntry = currentStorage[i];
        const fixtureEntry = fixtureStorage[i];
        const fields = ["label", "slot", "offset", "type", "contract"];
        for (const field of fields) {
            if (currentEntry[field] !== fixtureEntry[field]) {
                differences.push(
                    `storage[${i}].${field} mismatch: expected ${fixtureEntry[field]}, got ${currentEntry[field]}`
                );
            }
        }
        if (strict && stableStringify(currentEntry) !== stableStringify(fixtureEntry)) {
            differences.push(`storage[${i}] full entry mismatch`);
        }
    }
}

function diffTypeEntries(
    currentTypes: Record<string, any>,
    fixtureTypes: Record<string, any>,
    differences: string[]
) {
    const currentKeys = Object.keys(currentTypes).sort();
    const fixtureKeys = Object.keys(fixtureTypes).sort();

    if (currentKeys.length !== fixtureKeys.length) {
        differences.push(`types length mismatch: expected ${fixtureKeys.length}, got ${currentKeys.length}`);
    }

    const fixtureSet = new Set(fixtureKeys);
    for (const key of currentKeys) {
        if (!fixtureSet.has(key)) {
            differences.push(`types key missing in fixture: ${key}`);
        }
    }

    const currentSet = new Set(currentKeys);
    for (const key of fixtureKeys) {
        if (!currentSet.has(key)) {
            differences.push(`types key missing in current layout: ${key}`);
        }
    }

    const keysToCompare = currentKeys.filter((key) => fixtureSet.has(key));
    for (const key of keysToCompare) {
        const currentType = currentTypes[key];
        const fixtureType = fixtureTypes[key];
        const fields = ["label", "encoding", "numberOfBytes", "base"];
        for (const field of fields) {
            if (currentType[field] !== fixtureType[field]) {
                differences.push(
                    `types[${key}].${field} mismatch: expected ${fixtureType[field]}, got ${currentType[field]}`
                );
            }
        }

        const currentMembers = currentType.members || [];
        const fixtureMembers = fixtureType.members || [];
        if (currentMembers.length !== fixtureMembers.length) {
            differences.push(
                `types[${key}].members length mismatch: expected ${fixtureMembers.length}, got ${currentMembers.length}`
            );
        }

        const memberLength = Math.min(currentMembers.length, fixtureMembers.length);
        for (let i = 0; i < memberLength; i += 1) {
            const currentMember = currentMembers[i];
            const fixtureMember = fixtureMembers[i];
            const memberFields = ["label", "slot", "offset", "type"];
            for (const field of memberFields) {
                if (currentMember[field] !== fixtureMember[field]) {
                    differences.push(
                        `types[${key}].members[${i}].${field} mismatch: expected ${fixtureMember[field]}, got ${currentMember[field]}`
                    );
                }
            }
        }

        if (strict && stableStringify(currentType) !== stableStringify(fixtureType)) {
            differences.push(`types[${key}] full entry mismatch`);
        }
    }
}

const currentLayout = runForgeInspect(contractName);
const fixtureLayout: StorageLayout = JSON.parse(fs.readFileSync(fixtureAbsolute, "utf8"));

if (outputAbsolute) {
    fs.mkdirSync(path.dirname(outputAbsolute), { recursive: true });
    fs.writeFileSync(outputAbsolute, `${JSON.stringify(currentLayout, null, 2)}\n`);
}

const differences: string[] = [];
const currentStorage = Array.isArray(currentLayout.storage) ? currentLayout.storage : [];
const fixtureStorage = Array.isArray(fixtureLayout.storage) ? fixtureLayout.storage : [];
const currentTypes = currentLayout.types && typeof currentLayout.types === "object" ? currentLayout.types : {};
const fixtureTypes = fixtureLayout.types && typeof fixtureLayout.types === "object" ? fixtureLayout.types : {};

diffStorageEntries(currentStorage, fixtureStorage, differences);
diffTypeEntries(currentTypes as Record<string, any>, fixtureTypes as Record<string, any>, differences);

if (differences.length > 0) {
    console.error("Storage layout mismatch detected:");
    for (const difference of differences.slice(0, 20)) {
        console.error(`- ${difference}`);
    }
    if (differences.length > 20) {
        console.error(`- ...and ${differences.length - 20} more differences`);
    }
    process.exit(1);
}

console.log(`Storage layout matches fixture for ${contractName}.`);
