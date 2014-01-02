fs = require 'fs'
path = require 'path'
http = require 'http'
oracle = require 'oracle'
express = require 'express'
pool = require 'generic-pool'
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
        else
          rows.map cb
      dbpool.release conn


# get recent checkouts
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
    chargeDate = row.CHARGE_DATE
    chargeDate.setMinutes(chargeDate.getMinutes() + chargeDate.getTimezoneOffset())
    charge =
      itemId: row.ITEM_ID
      libraryId: row.LIBRARY_ID
      libraryName: row.LIBRARY_NAME
      chargeDate: chargeDate
    getBibData charge, cb

# remove some punctuation
clean = (s) ->
  if s
    s = s.replace(/^[./, ]+/, '')
    s = s.replace(/[./, ]+$/, '')
  return s

# get bibliographic information for a given charge
getBibData = (charge, cb) ->
  q = "
  SELECT bib_item.bib_id, bib_text.*
  FROM bib_item, bib_text
  WHERE bib_item.item_id = :1
    AND bib_item.bib_id = bib_text.bib_id
  "
  select q, [charge.itemId], (row) ->
    book =
      author: row.AUTHOR
      title: clean(row.TITLE_BRIEF)
      isbn: row.ISBN
      issn: row.ISSN
      publisher: row.PUBLISHER
      placeOfPublication: clean(row.PUB_PLACE)
      publicationDate: clean(row.PUBLISHER_DATE)
      imprint: clean(row.IMPRINT)
      language: row.LANGUAGE
      id: row.BIB_ID
      lccn: row.LCCN
      oclc: row.NETWORK_NUMBER
      libraryId: charge.libraryId
      libraryName: charge.libraryName
      itemId: charge.itemId
      charged: charge.chargeDate
    cb book

# helper for doing timeouts
delay = (ms, func) -> setTimeout func, ms


# function that polls for recent checkout activity
seen = {}
recent = [];
pollForCheckouts = (cb) ->
  recentCheckouts 20, (book) ->
    if not seen[book.id]
      if recent.length > 10
        recent = recent[1..10]
      recent.push book
      seen[book.id] = true
      cb book
  delay 3000, -> pollForCheckouts cb


# create the web app

home = (req, res) ->
  res.sendfile 'static/index.html'


app = express()
app.use '/static', express.static(__dirname + '/static')
app.get '/', home

server = http.createServer app

# configure socket.io

io = socketio.listen server
io.sockets.on 'connection', (socket) ->
  # the recent list can be out of order due to async db calls
  recent.sort (a, b) -> a.charged > b.charged ? 1 : a.charged < b.charged ? -1 : 0
  for book in recent
    socket.emit 'checkout', book

pollForCheckouts (book) ->
  io.sockets.emit 'checkout', book

# start up the server!

server.listen config.port



