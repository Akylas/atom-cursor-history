{CompositeDisposable, Disposable, TextEditor, Emitter} = require 'atom'
path = require 'path'
_    = require 'underscore-plus'

History    = require './history'
LastEditor = require './last-editor'
Flasher    = require './flasher'
settings   = require './settings'

module.exports =
  config: settings.config
  history: null
  subscriptions: null
  editorSubscriptions: null
  lastEditor: null
  locked: false

  # Experiment
  symbolsViewFileView: null
  symbolsViewProjectView: null
  modalPanelContainer: null

  onWillJumpToHistory: (callback) ->
    @emitter.on 'will-jump-to-history', callback

  onDidJumpToHistory:  (callback) ->
    @emitter.on 'did-jump-to-history', callback

  activate: (state) ->
    @subscriptions = new CompositeDisposable
    @editorSubscriptions = {}
    @emitter       = new Emitter
    @history       = new History settings.get('max')

    @rowDeltaToRemember = settings.get('rowDeltaToRemember')
    settings.onDidChange 'rowDeltaToRemember', ({newValue}) =>
      @rowDeltaToRemember = newValue

    atom.commands.add 'atom-workspace',
      'cursor-history:next':         => @next()
      'cursor-history:prev':         => @prev()
      'cursor-history:clear':        => @clear()
      'cursor-history:dump':         => @dump()
      'cursor-history:toggle-debug': => @toggleConfig('debug')

    @modalPanelContainer = atom.workspace.panelContainers['modal']

    @subscriptions.add @modalPanelContainer.onDidAddPanel ({panel, index}) =>
      # itemKind in ['GoToView', 'GoBackView', 'FileView', 'ProjectView']
      itemKind = panel.getItem().constructor.name
      return unless itemKind in ['FileView', 'ProjectView']
      switch itemKind
        when 'FileView'
          @handleSymbolsViewFileView panel
        when 'ProjectView'
          @handleSymbolsViewProjectView panel


    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      @editorSubscriptions[editor.id] = new CompositeDisposable
      @handleChangePath(editor)

      @editorSubscriptions[editor.id].add editor.onDidChangeCursorPosition (event) =>
        return if @isLocked()
        return if event.oldBufferPosition.row is event.newBufferPosition.row # for performance.
        setTimeout =>
          @handleCursorMoved event
        , 300

      @editorSubscriptions[editor.id].add editor.onDidDestroy =>
        @editorSubscriptions[editor.id]?.dispose()
        delete @editorSubscriptions[editor.id]

    @subscriptions.add atom.workspace.observeActivePaneItem (item) =>
      if item instanceof TextEditor and item.getURI()
        @handlePaneItemChanged item

    @subscriptions.add atom.workspace.onWillDestroyPaneItem ({item}) =>
      if item instanceof TextEditor and item.getURI()
        LastEditor.saveDestroyedEditor item

    @subscriptions.add @onWillJumpToHistory (direction) =>
      @lock()

    @subscriptions.add @onDidJumpToHistory (direction) =>
      @unLock()
      Flasher.flash() if settings.get('flashOnLand')
      @history.dump direction

    # @extendSymbolsView()

  extendSymbolsView: ->
    return unless pack = atom.packages.getLoadedPackage('symbols-view')

    libPath = path.join(atom.packages.resolvePackagePath('symbols-view') , 'lib', 'symbols-view')
    SymbolsView = require libPath
    _openTag = SymbolsView::openTag
    SymbolsView::openTag = (params...) ->
      # if @constructor
      # setTimeout =>
      #   console.log "before", @panel.isVisible()
      # , 300
      console.log "Before"
      console.log @stack
      console.log @constructor.name
      _openTag.call(this, params...)
      console.log "After"
      console.log @stack
      # setTimeout =>
      #   console.log "after", @panel.isVisible()
      # , 300

  handleChangePath: (editor) ->
    orgURI = editor.getURI()

    @editorSubscriptions[editor.id].add editor.onDidChangePath =>
      newURI = editor.getURI()
      @history.rename orgURI, newURI
      @lastEditor.rename orgURI, newURI
      orgURI = newURI

  handlePaneItemChanged: (item) ->
    # We need to track former active pane to know cursor position when active pane was changed.
    @lastEditor ?= new LastEditor(item)

    {editor, point, URI: lastURI} = @lastEditor.getInfo()
    if not @isLocked() and (lastURI isnt item.getURI())
      @history.add editor, point, lastURI, dumpMessage: "[Pane item changed] save history"

    @lastEditor.set item
    @debug "set LastEditor #{path.basename(item.getURI())}"

  handleCursorMoved: ({oldBufferPosition, newBufferPosition, cursor}) ->
    if @symbolsViewFileView?.panel.isVisible()
      console.log "Symbol View visible returning"
      return
    return if @isLocked()
    console.log "Moved!!"
    editor = cursor.editor
    return if editor.hasMultipleCursors()
    return unless URI = editor.getURI()
    # console.log

    if @needRemember(oldBufferPosition, newBufferPosition)
      @history.add editor, oldBufferPosition, URI, dumpMessage: "[Cursor moved] save history"

  withPanel: (panel, {onShow, onHide}) ->
    [oldEditor, oldPoint, newEditor, newPoint] = []
    panelSubscription = panel.onDidChangeVisible (visible) =>
      if visible
        @lock()
        {editor: oldEditor, point: oldPoint} = onShow()
      else
        {editor: newEditor, point: newPoint} = onHide()
        if @needRemember(oldPoint, newPoint)
          @history.add oldEditor, oldPoint, oldEditor.getURI(), dumpMessage: "[Cursor moved] save history"
        @unLock()

    @subscriptions.add panel.onDidDestroy ->
      panelSubscription.dispose()

  handleSymbolsViewFileView: (panel) ->
    @symbolsViewFileView ?= {panel, item: panel.getItem()}
    @withPanel panel,
      onShow: =>
        editor = @getActiveTextEditor()
        # At the timing symbol-views panel show, first item in symobls
        # already selected(this mean cursor position have changed).
        # So we can't use TexitEditor::getCursorBufferPosition(), fotunately,
        # symbols-view serialize buffer state initaially, we use this.
        point = panel.getItem().initialState?.bufferRanges[0].start
        {editor, point}
      onHide: =>
        editor = @getActiveTextEditor()
        point = editor.getCursorBufferPosition()
        {editor, point}
        # console.log "move from #{point.toString()} -> #{newPoint.toString()}"

    # [editor, point] = []
    # @symbolsViewFileView = {panel, item: panel.getItem()}
    # panelSubscription = panel.onDidChangeVisible (visible) =>
    #   if visible
    #     @lock()
    #     editor = @getActiveTextEditor()
    #     # At the timing symbol-views panel show, first item in symobls
    #     # already selected(this mean cursor position have changed).
    #     # So we can't use TexitEditor::getCursorBufferPosition(), fotunately,
    #     # symbols-view serialize buffer state initaially, we use this.
    #     point = panel.getItem().initialState?.bufferRanges[0].start
    #   else
    #     newPoint = editor.getCursorBufferPosition()
    #     # console.log "move from #{point.toString()} -> #{newPoint.toString()}"
    #     if @needRemember(point, newPoint)
    #       @history.add editor, point, editor.getURI(), dumpMessage: "[Cursor moved] save history"
    #     @unLock()
    #
    # @subscriptions.add panel.onDidDestroy ->
    #   panelSubscription.dispose()

  handleSymbolsViewProjectView: (panel) ->
    [editor, point] = []
    @symbolsViewProjectView = {panel, item: panel.getItem()}

    panelSubscription = panel.onDidChangeVisible (visible) =>
      if visible
        @lock()
        editor = @getActiveTextEditor()
        point = editor.getCursorBufferPosition()
      else
        setTimeout =>
          newPoint = @getActiveTextEditor().getCursorBufferPosition()
          console.log "move from #{point.toString()} -> #{newPoint.toString()}"
          if @needRemember(point, newPoint)
            @history.add editor, point, editor.getURI(), dumpMessage: "[Cursor moved] save history"
          @unLock()
        , 300

    @subscriptions.add panel.onDidDestroy ->
      panelSubscription.dispose()


  # Throttoling save to history once per 500ms.
  # When activePaneItem change and cursorMove event happened almost at once.
  # We pick activePaneItem change, and ignore cursor movement.
  # Since activePaneItem change happen before cursor movement.
  # Ignoring tail call mean ignoring cursor move happen just after pane change.
  # This is mainly for saving only target position on `symbols-view:goto-declaration` and
  # ignoring relaying position(first line of file of target position.)
  # saveHistory: (editor, point, URI, options)->
  #   @_saveHistory ?= _.throttle(@history.add.bind(@history), 500, trailing: false)
  #   @_saveHistory editor, point, URI, options

  # saveHistory: (editor, point, URI, options)->
  #   @_saveHistory ?= _.throttle(@history.add.bind(@history), 500, trailing: false)
  #   @_saveHistory editor, point, URI, options

  needRemember: (oldBufferPosition, newBufferPosition) ->
    # console.log "Called NeedRemember"
    # Line number delata exceeds or not.
    Math.abs(oldBufferPosition.row - newBufferPosition.row) > @rowDeltaToRemember

  lock:     -> @locked = true
  unLock:   -> @locked = false
  isLocked: -> @locked

  clear: -> @history.clear()

  next: -> @jump 'Next'
  prev: -> @jump 'Prev'

  jump: (direction) ->
    # Settings tab is not TextEditor instance.
    return unless activeEditor = @getActiveTextEditor()
    return unless entry = @history["get#{direction}"]()

    if direction is 'Prev' and @history.isNewest()
      point = activeEditor.getCursorBufferPosition()
      URI   = activeEditor.getURI()
      @history.pushToHead activeEditor, point, URI

    @emitter.emit 'will-jump-to-history', direction

    {URI, point} = entry

    if activeEditor.getURI() is URI
      # Jump within same paneItem

      # Intentionally disable `autoscroll` to set cursor position middle of
      # screen afterward.
      activeEditor.setCursorBufferPosition point, autoscroll: false
      # Adjust cursor position to middle of screen.
      activeEditor.scrollToCursorPosition()
      @emitter.emit 'did-jump-to-history', direction

    else
      # Jump to different pane
      options =
        searchAllPanes: settings.get('searchAllPanes')

      atom.workspace.open(URI, options).done (editor) =>
        editor.scrollToBufferPosition(point, center: true)
        editor.setCursorBufferPosition(point)
        @emitter.emit 'did-jump-to-history', direction

    # @history.dump direction

  deactivate: ->
    for editorID, disposables of @editorSubscriptions
      disposables.dispose()
    @editorSubscriptions = null
    @subscriptions.dispose()
    settings.dispose()
    @history?.destroy()
    @history = null

  debug: (msg) ->
    return unless settings.get('debug')
    console.log msg

  serialize: ->
    @history?.serialize()

  getActiveTextEditor: ->
    atom.workspace.getActiveTextEditor()

  dump: ->
    console.log @modalPanelContainer
    @history.dump '', true

  toggleConfig: (param) ->
    settings.toggle(param, true)
