request = require 'request'
express = require 'express'
async = require 'async'
optimist = require 'optimist'
redis = require 'redis'

github = require './github'

LEADERBOARD_KEY = "gitscore:leaderboard"
LEADERBOARD_RESULTS = 50


#
# Initialization
#

# Command line args
argv = optimist
  .usage("gitscore.com service.\nUsage: $0")
  .options("p",
     describe: "Runs the server on the specified port.",
     alias: "port",
     default: 3000
  )
  .argv

# Set up redis
redisClient = redis.createClient(process.env.REDIS_PORT || 6379, process.env.REDIS_HOST || "127.0.0.1")
redisClient.auth(process.env.REDIS_PASSWORD) if process.env.REDIS_PASSWORD

# Set up express
app = express.createServer();

app.configure ->
  app.set('views', __dirname + '/views');
  app.set('view engine', 'ejs');
  app.use(express.bodyParser());
  app.use(express.methodOverride());
  app.use(express.static(__dirname + '/public'));

app.configure "development", ->
  app.use(express.errorHandler({ dumpExceptions: true, showStack: true }));

app.configure "production", ->
  app.use(express.errorHandler());

console.log "Started gitscore on port #{argv.p}"
app.listen argv.p


#
# App endpoints
#

# Homepage
app.get '/', (req, res) ->
  leaderboard = fetchLeaderboardData 0, LEADERBOARD_RESULTS, (leaderboard) ->
    res.render "index",
      score: null
      position: null
      username: null
      leaderboard: leaderboard

# Score page
app.get '/user/:username', (req, res) ->
  req.connection.setTimeout(30000)

  leaderboard = fetchLeaderboardData 0, LEADERBOARD_RESULTS, (leaderboard) ->
    username = req.params.username.toLowerCase()
    fetchScoreData username, (scoreData) ->
      if scoreData["error"]
        score = 0
      else
        score = scoreData.scores.total

      redisClient.zrevrank LEADERBOARD_KEY, username, (err, position) ->
        if !err
          suffix = "th"
          position += 1
          lastChar = position.toString().substr(-1)
          if lastChar == '1'
            suffix = "st" if (position < 10 || position > 20)
          else if lastChar == '2'
            suffix = "nd" if (position < 10 || position > 20)
          else if lastChar == '3'
            suffix = "rd" if (position < 10 || position > 20)
          position = position + suffix
        else
          position = position + 1

        res.render "index",
          position: position
          score: score
          username: username
          leaderboard: leaderboard

# Fetch git stats from github api
app.get '/user/:username/calculate', (req, res) ->
  username = req.params.username.toLowerCase()
  fetchScoreData username, (scoreData) ->
    redisClient.zrevrank LEADERBOARD_KEY, username, (err, position) ->
      redisClient.zcard LEADERBOARD_KEY, (err, totalScores) ->
        scoreData["position"] = position + 1
        scoreData["totalScores"] = totalScores
        res.send scoreData

# Avatar redirect
app.get '/:username/avatar', (req, res) ->
  username = req.params.username.toLowerCase()
  cachedGet
    key: "gitscore:userAvatar:#{username}"
    expiry: 57600
    generator: (generate) ->
      github.user username, (err, user) ->
        if err?
          console.log "Error fetching avatar: #{err}"
          generate "", false
        else
          generate user.avatar_url, true

    callback: (response) ->
      res.redirect response


#
# Private methods
#

# Magic getter with redis cache passthrough
cachedGet = (opts) ->
  redisClient.get opts.key, (err, response) ->
    if response
      console.log "Cache hit for #{opts.key}"
      opts.callback response
    else
      console.log "Cache miss for #{opts.key}"
      opts.generator (response, cacheResult) ->
        if cacheResult
          redisClient.set(opts.key, response)
          redisClient.expire opts.key, opts.expiry if opts.expiry?
        opts.callback response

# Fetch a "page" (array slice) from the scores leaderboard
fetchLeaderboardData = (offset, count, completeCallback) ->
  # Fetch the top 'num' users by global score
  # ZREVRANGEBYSCORE key max min [WITHSCORES] [LIMIT offset count]
  redisClient.zrevrangebyscore LEADERBOARD_KEY, "+inf", "-inf", "WITHSCORES", "LIMIT", offset, count, (err, response) ->
    leaderboard = []
    if response?
      for el, idx in response
        continue if idx % 2

        leaderboard.push
          username: el
          score: response[idx+1]

    completeCallback leaderboard

# Fetch the score data for a particular username
fetchScoreData = (username, completeCallback) ->
  cachedGet
    key: "gitscore:scoreData:#{username}"
    expiry: 28800

    generator: (generate) ->
      github.userCombined username, (err, userData, throttle) ->
        if err?
          console.log "Error fetching user data: #{err}"
          generate JSON.stringify({
            error: err
            }), false
          return

        # Calculate the scores
        scoreData = calculate_score userData.user, userData.repos, userData.gists

        # Add this score to the leaderboard
        redisClient.zadd LEADERBOARD_KEY, scoreData.total, username

        # Done
        generate JSON.stringify({
          user:
            username: userData.user.login
            name: userData.user.name
            avatar: userData.user.avatar_url
            location: userData.user.location
          scores: scoreData
        }), true

    callback: (response) ->
      completeCallback JSON.parse(response)

calculate_score = (user, repos, gists) ->
  # Initialize the response
  scores =
    total: 0
    user: 0
    repo: 0
    gist: 0

  # Followers is a sign of reputation of the user
  scores.user += (user.followers) if user.followers

  # Calculate and add the score for each of the user's repo
  for repo in repos
    # No points for private repos
    continue if repo.private

    repoScore = 10                    # 10 points just for creating a repo
    repoScore += repo.watchers        # Watchers are an indication of an interesting repo
    repoScore += repo.forks           # Forks indicate heavy dev activity
    repoScore *= 2 unless repo.fork   # Double the score for originality

    # Add to the total
    scores.repo += repoScore

  # Bonus points for gists
  for gist in gists
    # No points for private gists
    continue unless gist.public

    # 10 points just for creating a gist
    gistScore = 10

    # Comments are an indication of an interesting gist
    gistScore += gist.comments

    # Add to the total
    scores.gist += gistScore

  # Total up points
  scores.total = scores.user + scores.repo + scores.gist

  return scores
