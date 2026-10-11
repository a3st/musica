import { readFileSync, existsSync } from 'node:fs';
import ts from 'typescript';

/** Загружает независимые TypeScript-модули в Node без отдельного сборщика тестов. */
export function moduleUrl(url) {
  const source = readFileSync(url, 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText.replace(/from '([.][^']+)'/g, (_, path) => {
    const file = new URL(path + '.ts', url);
    return `from '${moduleUrl(existsSync(file) ? file : new URL(path + '/index.ts', url))}'`;
  });
  return `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`;
}
