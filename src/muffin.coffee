# muffin.js: handy helpers for building cakefiles
# -------------------------------------------------
#
# Licensed under the MIT License, excluding cloc.pl
# Includes cloc.pl from http://cloc.sourceforge.net/, licensed under GPL V2

CoffeeScript     = require 'coffee-script'
# Require Q for all the handy promise based business
q                = require 'q'
fs               = require 'q-fs'
ofs              = require 'fs'
path             = require 'path'
glob             = require 'glob'
temp             = require 'temp'

# Require `child_process` and grab a reference to it so the identifier `exec` is free.
{spawn, exec}    = require 'child_process'
orgExec = exec

# Simple variadic extend
extend = (onto, others...) ->
  result = onto
  for o in others
    for k,v of o
      result[k] = v
  result

# Promise based version of `exec`.
exec = (command, options = {}) ->
  deferred = q.defer()
  # Wrap the execution of the original `exec` function in a deferred.
  child = orgExec(command, options, (error, stdout, stderr) ->
    if error?
      deferred.reject(error)
    else
      deferred.resolve([stdout, stderr])
  )

  # Return both the child process (for writing to stdin) and the promise.
  [child, deferred.promise]

# Internal helper function for deciding if the repo is in the midst of a rebase.
inRebase = ->
  path.existsSync('.git/rebase-apply')

ask = (question, format = /.+/) ->
  stdin = process.stdin
  stdout = process.stdout
  deferred = q.defer()

  stdin.resume()
  stdout.write(question + ": ")

  stdin.once 'data', (data) ->
    stdin.pause()
    data = data.toString().trim()
    if format.test(data) 
      deferred.resolve data
    else
      stdout.write "It should match: #{format}\n"
      deferred.resolve ask(question, format)

  deferred.promise

# Notifies the user of a success or error during compilation
notify = (source, origMessage, error = false) ->
  if error
    # If notifying about an error, make sure any errors actually reference the file being
    # compiled.
    basename = source.replace(/^.*[\/\\]/, '')
    if m = origMessage.match /Parse error on line (\d+)/
      message = "Parse error in #{basename}\non line #{m[1]}."
    else
      message = "Error in #{basename}."
    command = growlCommand '-n', 'Cake', '-p', '2', '-t', "\"Action failed\"", '-m', "\"#{message}\""
    # Always log any autogenerated messages as well as the error message to the console
    console.error message
    console.error origMessage
  else
    # Growl the successful action (usually a compilation) to the user, and always log it to the console as well.
    command = growlCommand '-n', 'Cake', '-p', '-1', '-t', "\"Action Succeeded\"", '-m', "\"#{source}\""
    console.log origMessage

  # Growl if we can, or
  if growlAvailble
    [child, promise] = exec command
  else
    # return an already fufilled promise if not
    promise = q.ref true
  promise

readFile = (file, options = {}) ->
  deferred = q.defer()

  # Read the file from the git index if we're using the stage as the files being caked,
  # or otherwise use `q-fs` to read the file and return a promise.
  if runOptions.commit
    [child, promise] = exec "git show :#{file}"
    child.stdin.setEncoding('utf8')
    child.stdin.end()
    q.when promise
    , (stdout, stderr) ->
      lines = stdout.toString().split('\n')
      lines.pop()
      str = lines.join('\n')
      deferred.resolve(str)
    , (reason) ->
      handleFileError(file, reason, options)
  else
    fs.read(file).then((contents) ->
      deferred.resolve(contents)
    , (reason) ->
      handleFileError(file, reason, options)
    )

  deferred.promise

writeFile = (file, data, options = {}) ->
  mode = options.mode || 644

  # Write the file to the git index if we're using the stage as the files being caked,
  # or otherwise use `q-fs` to write while returning a promise.
  if runOptions.commit

    # With git, it takes two stages to stage a file. We write the object to `git hash-object` over
    # stdin and wait for it to spit a sha back out. We then update the index with the new hashed
    # file using the sha as a reference and in the mode passed in.
    [child, promise] = exec "git hash-object --stdin -w"
    child.stdin.write(data)
    child.stdin.end()

    promise.then ([stdout, stderr]) ->
      sha = stdout.substr(0,40)
      [subchild, subpromise] = exec "git update-index --add --cacheinfo 100#{mode.toString(8)} #{sha} #{file}"
      return subpromise

    return promise
  else
    # Write the file, and then chmod the file using `q` promises.
    fs.write(file, data.toString(), "w", "UTF-8").then (data) ->
      return fs.chmod file, mode
    , (reason) ->
      # Make the common permissions error look a bit nicer.
      if reason.toString().match(/not writable/g)
        q.reject "#{file} isn't writable, please check permissions!"
      else
        q.reject(reason)

copyFile = (source, target, options = {}) ->
  # Read the file at the source and then write the file at the target
  readFile(source, options).then (contents) ->
    writeFile(target, contents, options).then ->
      notify source, "Moved #{source} to #{target} successfully"

# Handy promise based file error handler, which is a simple wrapper for `notify`
handleFileError = (file, err, options = {}) ->
  notify file, err.message, true unless options.notify == false

# Following 2 functions are stolen from Jitter, https://github.com/TrevorBurnham/Jitter/blob/master/src/jitter.coffee
# Compiles a script to a destination
compileScript = (source, target, options = {}) ->
  readFile(source, options).then (data) ->
    try
      js = CoffeeScript.compile data, {source, bare: options?.bare}
      writeFile(target, js, options).then ->
        notify source, "Compiled #{source} to #{target} successfully" unless options.notify == false
    catch err
      handleFileError target, err, options

# Generate a command to growl
growlCommand = (args...) ->
  args.unshift('growlnotify')
  args.join(' ')

# Check if growl is available so we can growl notifications only if growl is present
growlAvailble = false
orgExec growlCommand('--version'), (err, stdout, stderr) ->
  growlAvailble = err?

doccoFile = (source, options = {}) ->
  # Just tell docco to generate the one file by using it's command line helper
  [child, promise] = exec("docco #{source}")
  return promise.then ([stdout, stderr]) ->
    # Notify the user if any errors occured.
    notify source, stdout.toString() if stdout.toString().length > 0
    notify source, stderr.toString(), true if stderr.toString().length > 0

minifyScript = (source, options = {}) ->
  # Grab a reference to uglify. This isn't always globablly required since not everyone will minimize.
  {parser, uglify} = require("uglify-js")

  # Read the file and then step through the transformations of the AST.
  readFile(source, options).then (original) ->
    ast = parser.parse(original)  # Parse original JS code and get the initial AST.
    ast = uglify.ast_mangle(ast)  # Get a new AST with mangled names.
    ast = uglify.ast_squeeze(ast) # Get an AST with compression optimizations.
    final = uglify.gen_code(ast)
    finalPath = source.split('.')
    finalPath.pop()
    finalPath.push('min.js')
    # Write out the final code to the same file with a `min.js` extension instead of just `.js`. This
    # is also returned as a promise for chaining if need be.
    return writeFile(finalPath.join('.'), final, options)

# Internal function for finding the git root
getGitRoot = () ->
  [child, promise] = exec 'git rev-parse --show-toplevel'
  child.stdin.end()
  promise.then ([stdout, stderr]) ->
    stdout.toString().trim()

# Internal tracking variable and function used for asserting that Perl exists on the system muffin is being run on.
perlPresent = undefined
perlError = () -> throw 'You need a perl v5.3 or higher installed to do this with muffin.'
ensurePerl = () ->
  if perlPresent?
    perlError() unless perlPresent
  else
    orgExec 'perl --version', (error, stdout, stderr) ->
      if error?
        perlPresent = false
        perlError()

# Grab absolute references to the cloc file and language definition (an extension of the default one but including Coffeescript)
clocPath = path.normalize( __dirname + "/../deps/cloc.pl" )
langDefPath = path.normalize( __dirname + "/../deps/cloc_lang_def.txt")

# Use `cloc` in the deps dir to count the SLOC in the file.
clocFile = (filename) ->
  ensurePerl()
  # Grab the output of `cloc` in CSV.
  [child, promise] = exec "#{clocPath} --csv --read-lang-def=#{langDefPath} #{filename}"

  q.when promise, ([csv, stderr]) ->
    throw stderr.toString() if stderr.toString().length > 0

    # Split up the output into headers and CSV by splitting by double newline, and then into rows
    # by splitting by newline.
    [discard, csv] = csv.split("\n\n")
    rows = csv.split("\n")
    # Discard the row of column names, discard the empty newline at the end, and then split each row
    # into comma delimited columns.
    names = rows.shift()
    rows.pop()
    rows = rows.map (row) -> row.split(',')

    # Use the first row since we've only passed one file to `cloc`.
    row = rows[0]

    return {
      filename: filename
      filetype: row[1]
      blank: row[2]
      comment: row[3]
      sloc: row[4]
    }

# Use `fs.stat` to grab the filesize and modified time of a file.
statFile = (filename) ->
  q.when fs.stat(filename), (stats) ->
    # Convert the filesize (which comes in in bytes) into a more human readable form by
    # dividing by 1024 for each unit.
    size = stats.size
    units = ["bytes", "KB", "MB", "GB"]
    for unit in units
      break if size < 1024
      size = size / 1024

    # Round off the final value to two digits and set the size to a human readable string.
    size = "#{(Math.round(size*100)/100).toFixed(2)} #{unit}"

    return {
      size: size
      modified: stats.mtime
      filename: filename
    }

_statFiles = (files, options = {}) ->
  # For every file to be statted, `cloc` and `fs.stat` them both using the two respective helpers. These
  # both return promises which we join. For each file (and joined promise), ensure the promise resolves to
  # the merged stats objects from both helpers.
  promises = files.map (file) ->
    q.join clocFile(file), statFile(file), (clocstats, filestats) ->
      extend clocstats, filestats

  # Ensure any errors thrown during the join of the statting aren't swallowed by marking the promises as no longer
  # chainable.
  promise.end() for promise in promises

  # For every file's stats (or promise thereof), print out the row in the table. Do this by first figuring out
  # what the widest value in each column is, and then printing while padding all the shorter values out until they
  # reach the same length.
  q.all promises

printTable = (fields, results) ->
  # Add the headers to the top of the table.
  headers = {}
  for field in fields
    headers[field] = (field.charAt(0).toUpperCase() + field.slice(1))
  results.unshift headers

  # Figure out how wide each column must be, keyed by integer column index. Note that the header row is included
  # in the fields array here because a header may be the widest cell in the column.
  maxLengths = for field in fields
    max = Math.max.apply Math, results.map (result) -> 
      unless result[field]?
        console.error "Couldn't get value from #{field} on", result
        
      result[field].toString().length
    max + 2

  # Print out each row of results. Use a mutable array buffer which is then joined so new strings aren't created with a
  # bunch of += ops.
  for result in results
    out = []
    for field, i in fields
      data = result[field].toString()
      out.push ' ' for j in [data.length..maxLengths[i]]
      out.push data
    console.log out.join('')

  return results

# Logs a stats about files to the console for inspection.
statFiles = (files, options = {}) ->
  # If given a string, glob it to expand any wildcards.
  if typeof files is 'string'
    files = glob.globSync files

  # If we're comparing two shas, we need to check the two shas out somewhere else, and run the stats on all those files
  if options.compare
    fields = options.fields || ['filename', 'filetype']
    compareFields = options.compareFields || ['sloc', 'size']

    # Get the two git refs we are comparing
    ask('git ref A').then((refA) -> 
      ask('git ref B').then (refB) ->

        # Get the root of the git repository
        getGitRoot().then((root) ->

          clones = for ref in [refA, refB]
            do (ref) ->
              # Clone each root to a temporary directory and check out the given ref
              tmpdir = temp.mkdirSync()
              cloneCmd = "git clone #{root} #{tmpdir}"
              console.error cloneCmd
              [child, clone] = exec cloneCmd
              child.stdin.end()
            
              clone.then(([stdout, stderr]) ->
                [child, checkingOut] = exec "cd #{tmpdir} && git checkout #{ref}"
                checkingOut
              ).then () ->

                # Get an array of file paths relative to this temporary checkout
                clonedFiles = files.map (file) -> path.resolve(file).replace(root, tmpdir)

                # Stat the temporary files, and once the details come in, augment them with the original file's details
                _statFiles(clonedFiles, options).then (results) ->
                  for result, i in results
                    result['originalFilename'] = files[i]
                    result['ref'] = ref
                  results
          # Wait for all the clones and statting to finish.
          q.all(clones)
        ).then((results) ->
          
          # Build a table key'd by the original filename
          table = {}
          for resultSet in results
            for result in resultSet
              tableEntry = (table[result.originalFilename] ||= {})
              for k in fields
                tableEntry[k] = result[k]
              for k in compareFields
                tableEntry["#{k} at #{result.ref}"] = result[k]
          
          # Revert to the original filename
          results = for k, v of table
            v['filename'] = k
            v

          # Grab a list of the table fields
          tableFields = Array.prototype.slice.call fields
          for field in compareFields
            for ref in [refA, refB]
              tableFields.push "#{field} at #{ref}"
          printTable(tableFields, results)
        )
    ).end()
  else
    fields = options.fields || ['filename', 'filetype', 'sloc', 'size']
    _statFiles(files, options).then((results) ->
      printTable(fields, results)
    ).end()

# `compileMap` is an internal helper for taking the passed in options to `muffin.run` and turning strings
# into useful objects.
compileMap = (map) ->
  for pattern, action of map
    {pattern: new RegExp(pattern), action: action}

# Store a reference to the options that muffin was run with so we can ensure that none get lost if they don't get passed in by the user.
runOptions = {}

run = (args) ->
  # Grab the glob if not given by globbing a default string, globbing a given string, or globbing the array of given strings.
  if !args.files?
    args.files = glob.globSync './**/*'
  else if typeof args.files is 'string'
    args.files = glob.globSync args.files
  else
    args.files = args.files.reduce ((a, b) -> a.concat(glob.globSync(b))), []

  compiledMap = compileMap args.map
  
  # Save the reference to this run's options. Unfortuantly this renders muffin not many run safe. Bummer, for now.
  runOptions = args.options

  # Run the before callback, and wait till it finishes by wrapping it in a `q.ref` call to get a promise.
  before = -> q.ref if args.before then args.before() else true
  q.when start = before(),

    # Once the before callback has been successfully run, loop over all the pattern -> action pairs, and see if they
    # match any of the files in the array. If so, delete the file, and run the action.
    done = compiledMap.reduce (done, map) ->
      for i, file of args.files
        if matches = map.pattern.exec(file)
          delete args.files[i]
          # Do the job and wrap it in a promise if it didn't already return one using `q.ref`.
          work = q.ref map.action(matches)

          # Watch the file if the option was given.
          if args.options.watch
            if args.options.commit
              console.error "Can't watch committed versions of files, sorry!"
              process.exit 1
            do (map, matches) ->
              ofs.watchFile file, persistent: true, interval: 250, (curr, prev) ->
                return if curr.mtime.getTime() is prev.mtime.getTime()
                return if inRebase()
                q.when start = before(), ->
                  work = q.ref map.action(matches)
                  q.when work, (result) ->
                    args.after() if args.after
                  work.end()

                start.end()

          # Return another promise which will resolve to the work promise
          done = q.when(done, -> work)
      done
    , undefined

    q.when done, () ->
      args.after() if args.after
    done.end()

  start.end()

for k, v of {run, copyFile, doccoFile, notify, minifyScript, readFile, writeFile, compileScript, exec, extend, statFiles}
  exports[k] = v
