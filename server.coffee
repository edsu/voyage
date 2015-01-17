fs = require 'fs'
path = require 'path'
http = require 'http'
oracle = require 'oracle'
express = require 'express'
pool = require 'generic-pool'
whiskers = require 'whiskers'
socketio = require 'socket.io'

# read config
configPath = path.join __dirname, "config.json"
config = JSON.parse(fs.readFileSync(configPath))


# create database connection pool
dbpool = pool.Pool
  name: 'oracledb',
  create: (cb) ->
    console.log 'creating db connection'
    oracle.connect config.db, (err, conn) ->
      if err
        cb("connection failure", null)
      else
        cb(null, conn)
  destroy: (conn) ->
    console.log "closing db connection"
    conn.close()
  max: 1,
  min: 1


# helper for doing select queries
select = (q, params, cb) ->
  dbpool.acquire (err, conn) ->
    if err
      console.log "conn failure: ", err
    else
      conn.execute q, params, (err, rows) ->
        if err
          console.log "select failure: ", err
          dbpool.destroy conn
        else
          rows.map cb
      dbpool.release conn


# get recent checkouts
seen = {}  # XXX: this grows forever and should be purged somehow
recentCheckouts = (limit, cb) ->
  q = "
  SELECT * 
  FROM (
    SELECT ct.item_id AS item_id, 
      ct.charge_date AS charge_date, 
      li.library_id AS library_id,
      li.library_display_name as library_name
    FROM circ_transactions ct, 
      location lo, 
      library li
    WHERE ct.charge_date IS NOT NULL
      AND ct.charge_location = lo.location_id
      AND lo.library_id = li.library_id
    ORDER BY charge_date DESC)
  WHERE rownum <= :1
  "
  select q, [limit], (row) ->
    # not sure why the tz offset needs to be monkeyed with :(
    t = row.CHARGE_DATE
    t.setMinutes(t.getMinutes() + t.getTimezoneOffset())
    charge =
      itemId: row.ITEM_ID
      library: decodeLibrary(row.LIBRARY_NAME)
      created: t
    if not seen[charge.itemId]
      getBibData charge, cb
      seen[charge.itemId] = true


# helper to remove some punctuation
clean = (s) ->
  if s
    s = s.replace(/^[./, ]+/, '')
    s = s.replace(/[./, ]+$/, '')
  return s


# helper to cleanup isbns
cleanIsbn = (s) ->
  if s
    s = s.replace /[^0-9]/g, ''


# helper to look up library from config
decodeLibrary = (code) ->
  return config.libraries[code]


# get bibliographic information for a given charge
getBibData = (charge, cb) ->
  q = "
  SELECT bib_item.bib_id, bib_text.*, library.library_name AS owner
  FROM bib_item, bib_text, bib_master, item, location, library
  WHERE bib_item.item_id = :1
    AND bib_item.bib_id = bib_text.bib_id
    AND bib_item.item_id = item.item_id
    AND item.perm_location = location.location_id
    AND location.library_id = library.library_id
    AND bib_item.bib_id = bib_master.bib_id
    AND bib_master.suppress_in_opac != 'Y'
  "
  select q, [charge.itemId], (row) ->
    book =
      id: row.BIB_ID
      author: row.AUTHOR
      title: clean(row.TITLE_BRIEF)
      isbn: cleanIsbn(row.ISBN)
      issn: row.ISSN
      publisher: row.PUBLISHER
      placeOfPublication: clean(row.PUB_PLACE)
      publicationDate: clean(row.PUBLISHER_DATE)
      imprint: clean(row.IMPRINT)
      language: row.LANGUAGE
      lccn: row.LCCN
      oclc: row.NETWORK_NUMBER
      owner: decodeLibrary(row.OWNER)
      charge: charge
    cb book


# helper for doing timeouts
delay = (ms, func) -> setTimeout func, ms


# function that polls for recent checkout activity
recent = []
pollForCheckouts = (cb) ->
  recentCheckouts config.recentWindow, (book) ->
    if recent.length > config.recentWindow
      recent = recent[1..config.recentWindow]
    recent.push book
    cb book
  delay config.pollDelay, -> pollForCheckouts cb


# create the web app

home = (req, res) ->
  res.render 'index.html', {title: config.title}

app = express()
app.use '/static', express.static(__dirname + '/static')
app.engine '.html', whiskers.__express
app.set 'views', __dirname + '/views'
app.get '/', home
server = http.createServer app


# configure socket.io
io = socketio.listen server
io.sockets.on 'connection', (socket) ->
  # sort recents since they can be out of order due to async db calls
  recent.sort (a, b) -> return a.charge.created - b.charge.created
  for book in recent
    socket.emit 'checkout', book

# start looking for checkouts
pollForCheckouts (book) ->
  fs.appendFile 'journal.json', JSON.stringify(book) + "\n"
  io.sockets.emit 'checkout', book

# start up the server!
server.listen config.port
