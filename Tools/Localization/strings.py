#!/usr/bin/env python3
"""维护 App/Localizable.xcstrings 和 App/AppShortcuts.xcstrings（源语言简体中文，键即中文原文）。

  strings.py sync [DerivedData]   把编译产物里新出现的文案键并入目录（Localizable 不删旧键；
                                  AppShortcuts 和代码一一对应，代码里没有了的短语会删掉）
  strings.py merge en.json [语言]  把 {中文键: 译文} 并入目录，语言默认 en；值是列表时写成 Siri 短语组（stringSet），
                                  值是 {one: …, other: …} 时写成复数变体；含 ${applicationName} 的键进 AppShortcuts.xcstrings
  strings.py missing 语言 [文件]   把这种语言还没译的键导出成 {中文键: 英文参考}，交给翻译后再 merge
  strings.py check [语言…]         每个中文键在每种语言（默认 LANGS 全部）都要有译文，且格式占位符一致；有缺失时退出码为 1

支持的语言见 LANGS（都是从左往右的语言）；加一种语言要同时改 LANGS、工程 knownRegions 和 App/Localization.swift 的 AppLanguageChoice。

AppShortcuts.xcstrings 每个 App Shortcut 一个键（代码里的第一条短语），英文是整组短语，
每条都要含 ${applicationName}，参数占位符（如 ${target}）只能用键里有的。

sync 读取 Xcode 编译时生成的 *.stringsdata（需 SWIFT_EMIT_LOC_STRINGS=YES，工程已开启），
默认 DerivedData 为 /tmp/native-parity-build。中文 rawValue 枚举和 Embedded/engine 里的中文报错在运行时取译文，也会一并收录。
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, 'App', 'Localizable.xcstrings')
SHORTCUTS = os.path.join(ROOT, 'App', 'AppShortcuts.xcstrings')
APP_NAME = '${applicationName}'
# 含汉字或中文标点（「」，。：（）、 等）的键需要翻译。
HAN = re.compile(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]')
# 存成中文、显示时用 `.localized` 翻译的选项名（启动画面背景、文件夹颜色）。
RUNTIME_KEYS = {'自动', '取自图片', '白色', '黑色', '默认', '蓝色', '绿色', '橙色', '紫色', '红色'}
SPEC = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|lf|f|@|u|llu)|%%|\$\{\w+\}')
PARAM = re.compile(r'\$\{\w+\}')
LANGS = ['en', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'de', 'pt-BR', 'it', 'ru']
# 这些语言的译文里本来就有汉字，不查「译文里还有中文」。
HAN_LANGS = {'zh-Hant', 'ja'}


def load(path=CATALOG):
    if not os.path.exists(path):
        return {'sourceLanguage': 'zh-Hans', 'strings': {}, 'version': '1.0'}
    return json.load(open(path, encoding='utf-8'))


def save(doc, path=CATALOG):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(',', ' : '))
        f.write('\n')


# Both apps and their WidgetKit extensions share this catalog.
def stringsdata(derived):
    pattern = os.path.join(derived, 'Build/Intermediates.noindex/DSHLocal.build/*/DSHLocal.build/Objects-normal/*/*.stringsdata')
    files = glob.glob(pattern) + [f for t in ('PallasWidgets', 'PallasObserve', 'PallasMac', 'PallasMacWidgets')
                                  for f in glob.glob(pattern.replace('/DSHLocal.build/Objects', '/' + t + '.build/Objects'))]
    if not files:
        sys.exit('没有找到 stringsdata，请先编译：' + pattern)
    return files


def shortcut_keys(derived):
    """App Shortcuts 的键：编译时 appintentsmetadataprocessor 写出的 AppShortcuts 表。"""
    keys = set()
    for path in stringsdata(derived):
        keys.update(item['key'] for item in json.load(open(path, encoding='utf-8')).get('tables', {}).get('AppShortcuts', []))
    return keys


def source_keys(derived):
    keys = set()
    for path in stringsdata(derived):
        for table, items in json.load(open(path, encoding='utf-8')).get('tables', {}).items():
            if table != 'AppShortcuts':
                keys.update(item['key'] for item in items)
    for path in glob.glob(os.path.join(ROOT, 'App', '*.swift')):
        for line in open(path, encoding='utf-8'):
            if re.search(r'\benum \w+\s*:\s*String\b', line) or re.match(r'\s*case \w+ = "', line):
                keys.update(k for k in re.findall(r'= "([^"]*)"', line) if HAN.search(k))
    # 本机引擎抛给界面的中文报错（Error('…') / message:'…'），App 显示时按目录取译文。
    for path in glob.glob(os.path.join(ROOT, 'Embedded', 'engine', '*.[cm]js')):
        text = open(path, encoding='utf-8').read()
        keys.update(k for k in re.findall(r"(?:Error\(|message:\s*)'([^'\n]*)'", text) if HAN.search(k))
    return keys | RUNTIME_KEYS


def translated(entry, lang='en'):
    en = entry.get('localizations', {}).get(lang, {})
    if 'stringUnit' in en:
        return [en['stringUnit']['value']]
    if 'stringSet' in en:
        return list(en['stringSet'].get('values', []))
    plural = en.get('variations', {}).get('plural', {})
    return [v['stringUnit']['value'] for v in plural.values()]


def specs(text):
    return sorted(re.sub(r'\d+\$', '', s) for s in SPEC.findall(text))


def unit(value):
    if isinstance(value, list):
        return {'stringSet': {'state': 'translated', 'values': value}}
    if isinstance(value, dict):
        return {'variations': {'plural': {k: {'stringUnit': {'state': 'translated', 'value': v}} for k, v in value.items()}}}
    return {'stringUnit': {'state': 'translated', 'value': value}}


def needs_translation(key, entry):
    return HAN.search(key) and entry.get('shouldTranslate') is not False


def problems_in(strings, lang='en', shortcuts=False):
    problems = []
    for key, entry in strings.items():
        if not needs_translation(key, entry):
            continue
        values = translated(entry, lang)
        if not values:
            problems.append('缺' + lang + '：' + key)
        for v in values:
            if lang not in HAN_LANGS and re.search(r'[\u4e00-\u9fff]', v):
                problems.append(lang + ' 里还有中文：' + key)
            if shortcuts:
                if APP_NAME not in v:
                    problems.append(lang + ' Siri 短语缺 ' + APP_NAME + '：' + key + ' → ' + v)
                if not set(PARAM.findall(v)) <= set(PARAM.findall(key)):
                    problems.append(lang + ' Siri 短语的参数不在原文里：' + key + ' → ' + v)
            elif specs(v) != specs(key) and not (len(values) > 1 and specs(v) == []):
                problems.append(lang + ' 占位符不一致：' + key + ' → ' + v)
    return problems


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    doc = load()
    strings = doc.setdefault('strings', {})
    shortcut_doc = load(SHORTCUTS)
    shortcuts = shortcut_doc.setdefault('strings', {})
    if cmd == 'sync':
        derived = sys.argv[2] if len(sys.argv) > 2 else '/tmp/native-parity-build'
        added = 0
        for key in sorted(source_keys(derived)):
            if key not in strings:
                strings[key] = {} if HAN.search(key) else {'shouldTranslate': False}
                added += 1
        save(doc)
        print('新增', added, '个键')
        current = shortcut_keys(derived)
        new = sorted(current - shortcuts.keys())
        stale = sorted(shortcuts.keys() - current)
        for key in new:
            shortcuts[key] = {}
        for key in stale:
            del shortcuts[key]
        if current or os.path.exists(SHORTCUTS):
            save(shortcut_doc, SHORTCUTS)
        print('Siri 短语：新增', len(new), '个，删除', len(stale), '个', ('（' + '、'.join(stale) + '）') if stale else '')
    elif cmd == 'merge':
        lang = sys.argv[3] if len(sys.argv) > 3 else 'en'
        if lang not in LANGS:
            sys.exit('不支持的语言：' + lang)
        touched = False
        for key, value in json.load(open(sys.argv[2], encoding='utf-8')).items():
            if key in shortcuts or APP_NAME in key:
                shortcuts.setdefault(key, {}).setdefault('localizations', {})[lang] = unit(value if isinstance(value, list) else [value])
                touched = True
            else:
                strings.setdefault(key, {}).setdefault('localizations', {})[lang] = unit(value)
        save(doc)
        if touched:
            save(shortcut_doc, SHORTCUTS)
    elif cmd == 'missing':
        lang = sys.argv[2]
        def reference(entry):
            en = entry.get('localizations', {}).get('en', {})
            if 'variations' in en:
                return {k: v['stringUnit']['value'] for k, v in en['variations']['plural'].items()}
            values = translated(entry)
            return values if 'stringSet' in en else (values[0] if values else '')
        todo = {key: reference(entry) for table in (strings, shortcuts) for key, entry in sorted(table.items())
                if needs_translation(key, entry) and not translated(entry, lang)}
        text = json.dumps(todo, ensure_ascii=False, indent=1)
        if len(sys.argv) > 3:
            open(sys.argv[3], 'w', encoding='utf-8').write(text + '\n')
            print(lang, '待翻译', len(todo), '个键')
        else:
            print(text)
    elif cmd == 'check':
        problems = [p for lang in (sys.argv[2:] or LANGS)
                    for p in problems_in(strings, lang) + problems_in(shortcuts, lang, shortcuts=True)]
        print('\n'.join(problems) or '文案目录完整')
        sys.exit(1 if problems else 0)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
