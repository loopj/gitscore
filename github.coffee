request = require "request"
async   = require "async"

HEADERS = {"User-Agent": "gitscore"}

class Github
  # Just a namespace

Github.user = (username, callback) ->
  request {url: "https://api.github.com/users/#{username}", headers: HEADERS}, (error, response, body) ->
    error = "Unable to lookup user #{username}" if !error and response.statusCode != 200
    responseContent = JSON.parse(body)
    error = "#{username} is an organization, gitscore only supports users." if responseContent.type == "Organization"
    callback(error, responseContent, response.headers["x-ratelimit-remaining"]) if callback

Github.userRepos = (username, callback) ->
  request {url: "https://api.github.com/users/#{username}/repos", headers: HEADERS}, (error, response, body) ->
    error = "Unable to lookup user #{username}" if !error and response.statusCode != 200
    callback(error, JSON.parse(body), response.headers["x-ratelimit-remaining"]) if callback

Github.userGists = (username, callback) ->
  request {url: "https://api.github.com/users/#{username}/gists", headers: HEADERS}, (error, response, body) ->
    error = "Unable to lookup user #{username}" if !error and response.statusCode != 200
    callback(error, JSON.parse(body), response.headers["x-ratelimit-remaining"]) if callback

Github.userCombined = (username, callback) ->
  userData = {}
  throttle = 0

  async.auto
    user: (callback) ->
      Github.user username, (error, response, throttle_val) ->
        if error
          callback(error)
          return
        throttle = throttle_val
        userData.user = response
        callback()

    repos: (callback) ->
      Github.userRepos username, (error, response, throttle_val) ->
        if error
          callback(error)
          return
        throttle = throttle_val
        userData.repos = response
        callback()

    gists: (callback) ->
      Github.userGists username, (error, response, throttle_val) ->
        if error
          callback(error)
          return
        throttle = throttle_val
        userData.gists = response
        callback()

    , (err) ->
      callback err, userData, throttle

module.exports = Github
