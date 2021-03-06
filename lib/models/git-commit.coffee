{CompositeDisposable} = require 'atom'
fs = require 'fs-plus'
Path = require 'flavored-path'

git = require '../git'
notifier = require '../notifier'
splitPane = require '../splitPane'
GitPush = require './git-push'
GitPull = require './git-pull'

disposables = new CompositeDisposable

dir = (repo) ->
  (git.getSubmodule() or repo).getWorkingDirectory()

getStagedFiles = (repo) ->
  git.stagedFiles(repo).then (files) ->
    if files.length >= 1
      git.cmd(['status'], cwd: repo.getWorkingDirectory())
    else
      Promise.reject "Nothing to commit."

getTemplate = (cwd) ->
  git.getConfig('commit.template', cwd).then (filePath) ->
    if filePath then fs.readFileSync(Path.get(filePath.trim())).toString().trim() else ''

prepFile = (status, filePath) ->
  cwd = Path.dirname(filePath)
  git.getConfig('core.commentchar', cwd).then (commentchar) ->
    commentchar = if commentchar then commentchar.trim() else '#'
    status = status.replace(/\s*\(.*\)\n/g, "\n")
    status = status.trim().replace(/\n/g, "\n#{commentchar} ")
    getTemplate(cwd).then (template) ->
      fs.writeFileSync filePath,
        """#{template}
        #{commentchar} Please enter the commit message for your changes. Lines starting
        #{commentchar} with '#{commentchar}' will be ignored, and an empty message aborts the commit.
        #{commentchar}
        #{commentchar} #{status}"""

destroyCommitEditor = ->
  atom.workspace?.getPanes().some (pane) ->
    pane.getItems().some (paneItem) ->
      if paneItem?.getURI?()?.includes 'COMMIT_EDITMSG'
        if pane.getItems().length is 1
          pane.destroy()
        else
          paneItem.destroy()
        return true

commit = (directory, filePath) ->
  args = ['commit', '--cleanup=strip', "--file=#{filePath}"]
  git.cmd(args, cwd: directory)
  .then (data) ->
    notifier.addSuccess data
    destroyCommitEditor()
    git.refresh()

cleanup = (currentPane, filePath) ->
  currentPane.activate() if currentPane.alive
  disposables.dispose()
  try fs.unlinkSync filePath

showFile = (filePath) ->
  atom.workspace.open(filePath, searchAllPanes: true).then (textEditor) ->
    if atom.config.get('git-plus.openInPane')
      splitPane(atom.config.get('git-plus.splitPane'), textEditor)
    else
      textEditor

module.exports = (repo, {stageChanges, andPush}={}) ->
  filePath = Path.join(repo.getPath(), 'COMMIT_EDITMSG')
  currentPane = atom.workspace.getActivePane()
  init = -> getStagedFiles(repo).then (status) -> prepFile status, filePath
  startCommit = ->
    showFile filePath
    .then (textEditor) ->
      disposables.add textEditor.onDidSave ->
        commit(dir(repo), filePath)
        .then -> GitPush(repo) if andPush
      disposables.add textEditor.onDidDestroy -> cleanup currentPane, filePath
    .catch (msg) -> notifier.addError msg

  if stageChanges
    git.add(repo, update: stageChanges).then -> init().then -> startCommit()
  else
    init().then -> startCommit()
    .catch (message) ->
      if message.includes 'CRLF'
        startCommit()
      else
        notifier.addInfo message
