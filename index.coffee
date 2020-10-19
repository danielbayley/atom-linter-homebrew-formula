import {promisify} from 'util'
import {readFile} from 'fs'
import * as path from 'path'
import {exec} from 'child_process'
import { CompositeDisposable, Range } from 'atom'
import {name} from './package'#.json

read  = promisify readFile
shell = promisify exec

{ HOMEBREW_PREFIX, PREFIX, HOMEBREW_LIBRARY, HOMEBREW_BREW_FILE } = process.env
HOMEBREW_PREFIX ?= PREFIX or '/usr/local'
HOMEBREW_LIBRARY ?= "#{HOMEBREW_PREFIX}/Homebrew/Library"

config =
  executablePath:
    type: 'string'
    default: HOMEBREW_BREW_FILE or "#{HOMEBREW_PREFIX}/bin/brew"

  online:
    type: 'boolean'
    description: "Run additional slower `brew audit --new-formula` checks that require a network connection."
    default: false

grammarScopes = ['source.ruby']

capitalise = (l) => switch l
  when '-' then ' '
  when ':' then ': '
  else l.toUpperCase()

formulae = (file) =>
  content = file?.lineForRow? 0
  content ?= await read file, 'utf8'
  regex = /^(?<cask>cask)\s+['"][-\w]+['"]\s+do|<\s+(?<formula>Formula)/
  try {groups} = content.match regex
  return groups?.formula ? groups?.cask ? false

subs = new CompositeDisposable

fix = (file) =>
  if formula = await formulae file
    brew = atom.config.get "#{name}.executablePath"
    command = "#{brew} cask" if formula is 'cask'
    try await shell "#{command} style --fix '#{file}'"
    return file

buffer = false
lint = (editor) =>
  {buffer} = editor
  { dir, base } = path.parse file = buffer.file?.path

  switch await formulae buffer
    when 'Formula'
      command = ['audit --']
      command[0] += if atom.config.get "#{name}.online" then 'new-formula' else 'strict'      
      url = 'https://docs.brew.sh/Formula-Cookbook'

    when 'cask'
      url = 'https://github.com/Homebrew/homebrew-cask/blob/master/doc/development/adding_a_cask.md'

      command = ['cask style', 'cask audit --strict']
      buffer.scan /appcast/, ({range}) =>
        unless editor.isBufferRowCommented range.start.row
          command[1] += ' --appcast'

  brew = atom.config.get "#{name}.executablePath"
  affix = (command) => "#{brew} #{command} '#{file}'"

  line = /[^#]*?(?=\s+#)/

  try throw await shell command.map(affix).join('&'), cwd: dir
  catch {stdout}
    return [] unless stdout
    style = stdout.matchAll ///^#{base}:([0-9]+):.*?([0-9]+).*:\s*(.+)$///gm

    offenses = Array.from style, ([, ...start, excerpt ]) =>
      [ row, column ] = start.map (i) => Number i - 1
      position = buffer.rangeForRow row
      position.start.column = column
      buffer.scanInRange line, position, ({range}) =>
        position.end = range.end
      return [ position, excerpt ]

    repo = "#{HOMEBREW_LIBRARY}/Taps/homebrew/homebrew-cask"
    md = await read "#{repo}/doc/cask_language_reference/all_stanzas.md", 'utf8'
    grep = md.matchAll /^\|\s+`(\w+)[`\s]/gm
    stanzas = Array.from grep, ([, stanza]) => stanza

    error = ///^\s*(?:Error:|-)\s+(.*?(#{stanzas.join '|'})\b.+)$///gm
    audit = Array.from stdout.matchAll error

    audit.forEach ([, excerpt, stanza ]) =>
      switch
        when excerpt.includes 'appcast should not use'
          stanza = 'version'
        when excerpt.includes 'stanza'
          offenses.push [ new Range, excerpt ]
          return
      buffer.scan ///#{stanza + line.source}///, ({range}) =>
        offenses.push [ range, excerpt.replace /:$/m, '.']

    return offenses
      .filter ([, excerpt ]) =>
        not excerpt.includes 'frozen string literal comment'

      .map ([ position, excerpt ]) =>
        { start, end } = position
        indent = editor.indentationForBufferRow start.row
        indent *= editor.getTabLength()

        switch
          when start.column < indent
            line = buffer.rangeForRow start.row
            end.column = line.end.column
            start.column = indent
          when /space after `?#/.test excerpt
            end.column = start.column + 1
          when excerpt.includes 'comma after'
            start.column = end.column - 1
          when excerpt.includes 'slash after the domain'
            start.column = (end.column -= 1) - 1
          when /appcast|stanza/.test excerpt then cask = 1

        return {
          severity: 'error'
          linterName: "brew #{command[cask ? 0]}"
          location: { file, position }
          excerpt
          url
          solutions: [{ position, apply: => fix file }]
        }

linter = => { name, grammarScopes, scope: 'file', lintsOnChange: false, lint }

activate = =>
  command = "#{name}:fix-file"

  { scopeName, fileTypes } = atom.grammars.grammars.find ({name}) => name?.includes 'Homebrew'
  grammarScopes.push scopeName

  context = grammarScopes.map (scopeName) =>
    selector = scopeName.replace /\./g, ' '
    "atom-text-editor:not([mini])[data-grammar='#{selector}']"
  
  subs.add atom.commands.add context.join(), [command]: => fix buffer.file?.path

  ext = ".#{fileTypes[0]}"
  rb = (file) => file.endsWith ext

  subs.add atom.commands.add '.tree-view .selected', [command]: =>
    subs.add atom.packages.serviceHub.consume 'tree-view', '^1.0.0', (tree) =>
      fixed = await Promise.all tree.selectedPaths().filter(rb).map fix
      fixed.map(path.parse).forEach ({base}) =>
        description = "#{base} was `--fix`ed."
        atom.notifications.addSuccess name, {description}

  label = "#{command.replace /\b([a-z])|[-:]/g, capitalise}s"

  context = ".tree-view .file [data-name$='#{ext}']"
  subs.add atom.contextMenu.add [context]: [
    label: "Linter", submenu: [{ label, command }]
  ]

deactivate = => subs.dispose()

export { config, activate, linter, deactivate }
