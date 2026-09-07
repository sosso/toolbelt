-- Menu bar item: my open pull requests, bucketed by whether they can merge.
--
-- One `gh api graphql` search call covers every repo at once, so the poll cost
-- is a single request no matter how many PRs are open.

local util = require("util")

local M = {}

local config = {
  searchQuery = "is:pr is:open author:@me archived:false",
  refreshSeconds = 300,
  -- Every row is laid out in this many monospaced characters, which is what
  -- lines the number, title and age columns up down the whole menu.
  rowWidth = 104,
  rowSize = 14,
  -- Rows shown inline per section; the rest fold into a "N older" submenu.
  maxRowsPerSection = 10,
  openAllStaggerSeconds = 0.2,
  notifyOnNewFailure = true,
  ghCandidates = { "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh" },
}

local QUERY = [[
query($q: String!) {
  search(query: $q, type: ISSUE, first: 60) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        isDraft
        mergeable
        reviewDecision
        headRefName
        createdAt
        updatedAt
        repository { nameWithOwner }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { state } } }
        }
      }
    }
  }
}
]]

local menubar, timer, sleepWatcher
local gh = util.findExecutable(config.ghCandidates)
local state = { prs = nil, error = nil, fetchedAt = nil, loading = false }
-- Keyed by PR url, all surviving across polls: the last bucket seen, the last
-- definite mergeability GitHub gave, and which broken state was announced.
local lastVerdicts, lastMergeable, notified = {}, {}, {}

-- Menu order, most actionable first. `color` paints the menu bar count;
-- `tone` names the entry in the theme palette used for menu rows.
local BUCKETS = {
  { key = "ready", label = "Ready to merge", symbol = "✓", color = util.colors.green, tone = "green" },
  { key = "failing", label = "CI failing", symbol = "✗", color = util.colors.red, tone = "red" },
  { key = "pending", label = "CI running", symbol = "●", color = util.colors.orange, tone = "orange" },
  { key = "conflict", label = "Conflicts", symbol = "⚠", color = util.colors.orange, tone = "orange" },
  { key = "other", label = "No checks", symbol = "?", color = util.colors.faint, tone = "secondary" },
  { key = "draft", label = "Drafts", symbol = "◌", color = util.colors.faint, tone = "faint" },
}

-- The menu bar title stays in "what is broken" order, which is not the order
-- the menu reads in.
local TITLE_ORDER = { "conflict", "failing", "pending", "ready" }

local function rollupState(pr)
  local commits = pr.commits and pr.commits.nodes
  local commit = commits and commits[1] and commits[1].commit
  local rollup = commit and commit.statusCheckRollup
  return rollup and rollup.state or nil
end

-- GitHub computes mergeability lazily: it answers UNKNOWN while recomputing,
-- which it does for every open PR whenever the base branch moves. Treating that
-- as an answer flips a conflicting PR out of `conflict` and back again on the
-- next poll, so the last definite answer is carried forward instead.
local function mergeableOf(pr)
  if pr.mergeable and pr.mergeable ~= "UNKNOWN" then
    lastMergeable[pr.url] = pr.mergeable
    return pr.mergeable
  end
  return lastMergeable[pr.url]
end

local function classify(pr)
  local checks = rollupState(pr)
  local mergeable = mergeableOf(pr)
  if mergeable == "CONFLICTING" then return "conflict", checks end
  if checks == "FAILURE" or checks == "ERROR" then return "failing", checks end
  if pr.isDraft then return "draft", checks end
  if checks == "PENDING" or checks == "EXPECTED" then return "pending", checks end
  if checks == "SUCCESS" and mergeable == "MERGEABLE" then return "ready", checks end
  return "other", checks
end

local function bucketed()
  local groups = {}
  for _, bucket in ipairs(BUCKETS) do groups[bucket.key] = {} end
  for _, pr in ipairs(state.prs or {}) do
    table.insert(groups[pr.bucket], pr)
  end
  return groups
end

local function updateTitle()
  if not menubar then return end

  if state.error then
    return menubar:setTitle(util.styled({ { "PR ", util.colors.faint }, { "⚠", util.colors.red } }))
  end
  if not state.prs then
    return menubar:setTitle(util.styled({ { "PR …", util.colors.faint } }))
  end

  local groups = bucketed()
  local byKey = {}
  for _, bucket in ipairs(BUCKETS) do byKey[bucket.key] = bucket end

  local runs = { { "PR", util.colors.faint } }
  for _, key in ipairs(TITLE_ORDER) do
    local count = #groups[key]
    if count > 0 then
      table.insert(runs, { string.format(" %d%s", count, byKey[key].symbol), byKey[key].color })
    end
  end
  if #runs == 1 then table.insert(runs, { " 0", util.colors.faint }) end
  menubar:setTitle(util.styled(runs))
end

local BROKEN = { failing = true, conflict = true }

-- Fires only on a PR crossing from healthy into broken, and at most once per
-- crossing: `notified` latches until the PR is seen healthy again, so a bucket
-- that flaps between the two broken states — or across a poll where the data
-- was incomplete — cannot re-announce itself.
local function notifyNewFailures(prs)
  if not config.notifyOnNewFailure then return end
  local seen = {}

  for _, pr in ipairs(prs) do
    seen[pr.url] = pr.bucket
    local was = lastVerdicts[pr.url]

    if not BROKEN[pr.bucket] then
      notified[pr.url] = nil
    elseif was and not BROKEN[was] and not notified[pr.url] then
      notified[pr.url] = pr.bucket
      hs.notify.new(function() hs.urlevent.openURL(pr.url) end, {
        title = pr.bucket == "failing" and "CI failed" or "PR now conflicts",
        subTitle = string.format("#%d %s", pr.number, pr.repository.nameWithOwner),
        informativeText = pr.title,
        withdrawAfter = 0,
      }):send()
    end
  end

  -- A PR missing from this poll (merged, closed, or a truncated result) keeps
  -- its latch rather than being treated as newly healthy.
  for url in pairs(seen) do lastVerdicts[url] = seen[url] end
end

local function refresh()
  if state.loading then return end
  state.loading = true

  util.run(gh, { "api", "graphql", "-f", "q=" .. config.searchQuery, "-f", "query=" .. QUERY },
    function(code, out, err)
      state.loading = false
      state.fetchedAt = os.time()

      if code ~= 0 then
        state.error = (err ~= "" and err or out):gsub("%s+$", "")
        return updateTitle()
      end

      local ok, decoded = pcall(hs.json.decode, out)
      local nodes = ok and decoded and decoded.data and decoded.data.search and decoded.data.search.nodes
      if not nodes then
        state.error = "unreadable response from gh"
        return updateTitle()
      end

      local prs = {}
      for _, pr in ipairs(nodes) do
        if pr.number then
          pr.bucket, pr.checks = classify(pr)
          table.insert(prs, pr)
        end
      end
      table.sort(prs, function(a, b)
        local repoA, repoB = a.repository.nameWithOwner, b.repository.nameWithOwner
        if repoA ~= repoB then return repoA < repoB end
        return (a.createdAt or "") > (b.createdAt or "")
      end)

      state.error = nil
      state.prs = prs
      notifyNewFailures(prs)
      updateTitle()
    end)
end

local function reviewNote(pr)
  if pr.reviewDecision == "APPROVED" then return "approved" end
  if pr.reviewDecision == "CHANGES_REQUESTED" then return "changes requested" end
  if pr.reviewDecision == "REVIEW_REQUIRED" then return "review required" end
  return nil
end

local function prMenuItem(pr, p)
  local review = reviewNote(pr)
  local flags = {}
  if review then table.insert(flags, review) end
  if pr.mergeable == "UNKNOWN" then table.insert(flags, "unknown mergeability") end

  local number = string.format("#%-6d ", pr.number)
  local age = util.ago(pr.createdAt)
  local flagText = #flags > 0 and (table.concat(flags, " · ") .. "  ") or ""
  local room = config.rowWidth - util.len(number) - util.len(flagText) - util.len(age) - 8

  local title = util.row(config.rowWidth, config.rowSize, {
    { "    " },
    { number, { color = p.faint } },
    { util.truncate(pr.title, room), { color = p.primary } },
    { "", gap = true },
    { flagText, { color = p.cyan } },
    { age .. "  ", { color = p.faint } },
  })

  return {
    title = title,
    tooltip = string.format("%s #%d\n%s\n\n%s\nopened %s · updated %s",
      pr.repository.nameWithOwner, pr.number, pr.title, pr.headRefName,
      util.ago(pr.createdAt), util.ago(pr.updatedAt)),
    fn = util.openURL(pr.url),
    menu = {
      { title = util.row(38, config.rowSize,
        { { "  Open pull request", { color = p.primary } } }), fn = util.openURL(pr.url) },
      { title = util.row(38, config.rowSize,
        { { "  Open checks", { color = p.primary } } }), fn = util.openURL(pr.url .. "/checks") },
      { title = "-" },
      { title = util.row(38, config.rowSize,
        { { "  Copy branch", { color = p.cyan } } }), fn = util.copy(pr.headRefName) },
      { title = util.row(38, config.rowSize,
        { { "  Copy URL", { color = p.cyan } } }), fn = util.copy(pr.url) },
      { title = "-" },
      { title = util.row(38, config.rowSize,
        { { "  opened " .. util.ago(pr.createdAt), { color = p.faint } },
          { "", gap = true },
          { "updated " .. util.ago(pr.updatedAt) .. "  ", { color = p.faint } } }),
        disabled = true },
    },
  }
end

-- Firefox drops URLs handed to it in a tight loop, so the tabs are staggered.
local function openAll(prs)
  return function()
    for i, pr in ipairs(prs) do
      hs.timer.doAfter((i - 1) * config.openAllStaggerSeconds, function()
        hs.urlevent.openURL(pr.url)
      end)
    end
  end
end

local function groupByRepo(prs)
  local byRepo = {}
  for _, pr in ipairs(prs) do
    local repo = pr.repository.nameWithOwner
    byRepo[repo] = byRepo[repo] or {}
    table.insert(byRepo[repo], pr)
  end
  return byRepo
end

-- One slice of a section's rows, under a repo heading that opens that repo's
-- whole group — `byRepo` spans the entire section, so a heading rendered above
-- the inline rows still opens the ones folded into the overflow submenu. The
-- list arrives sorted by repo, so a heading starts at every boundary.
local function repoGroupedRows(prs, byRepo, p)
  local rows, currentRepo = {}, nil

  for _, pr in ipairs(prs) do
    local repo = pr.repository.nameWithOwner
    if repo ~= currentRepo then
      currentRepo = repo
      local group = byRepo[repo]
      table.insert(rows, {
        title = util.row(config.rowWidth, config.rowSize, {
          -- Owner dropped for width; the row's tooltip carries owner/repo.
          { "  " .. repo:gsub("^.*/", ""), { color = p.purple } },
          { "", gap = true },
          { string.format("open all %d  ", #group), { color = p.faint } },
        }),
        tooltip = string.format("Open all %d %s pull requests", #group, repo),
        fn = openAll(group),
      })
    end
    table.insert(rows, prMenuItem(pr, p))
  end
  return rows
end

local function sectionHeader(bucket, count, p)
  local tone = p[bucket.tone]
  return {
    title = util.row(config.rowWidth, config.rowSize, {
      { " " .. bucket.symbol .. "  " .. bucket.label:upper(), { color = tone, bold = true } },
      { "", gap = true },
      { tostring(count) .. "  ", { color = tone } },
    }),
  }
end

local function buildMenu()
  refresh()

  local p = util.palette()

  if not gh then
    return { { title = util.row(config.rowWidth, config.rowSize,
      { { "  gh not found — brew install gh", { color = p.red } } }), disabled = true } }
  end
  if state.error then
    return {
      { title = util.row(config.rowWidth, config.rowSize,
        { { "  gh call failed", { color = p.red } } }), disabled = true },
      { title = util.row(config.rowWidth, config.rowSize,
        { { "  " .. util.truncate(state.error, config.rowWidth - 4), { color = p.secondary } } }),
        disabled = true },
      { title = "-" },
      { title = util.row(config.rowWidth, config.rowSize,
        { { "  Retry now", { color = p.cyan } } }), fn = refresh },
    }
  end
  if not state.prs then
    return { { title = util.row(config.rowWidth, config.rowSize,
      { { "  Loading…", { color = p.faint } } }), disabled = true } }
  end

  local groups = bucketed()
  local items = {}

  for _, bucket in ipairs(BUCKETS) do
    local prs = groups[bucket.key]
    if #prs > 0 then
      if #items > 0 then table.insert(items, { title = "-" }) end
      table.insert(items, sectionHeader(bucket, #prs, p))

      local inline, overflow = prs, {}
      if #prs > config.maxRowsPerSection then
        inline, overflow = {}, {}
        for i, pr in ipairs(prs) do
          table.insert(i <= config.maxRowsPerSection and inline or overflow, pr)
        end
      end

      local byRepo = groupByRepo(prs)
      for _, row in ipairs(repoGroupedRows(inline, byRepo, p)) do table.insert(items, row) end
      if #overflow > 0 then
        table.insert(items, {
          title = util.row(config.rowWidth, config.rowSize,
            { { string.format("    %d older…", #overflow), { color = p.faint } } }),
          menu = repoGroupedRows(overflow, byRepo, p),
        })
      end
    end
  end

  if #items == 0 then
    table.insert(items, {
      title = util.row(config.rowWidth, config.rowSize,
        { { "  No open pull requests", { color = p.secondary } } }),
      disabled = true,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = util.row(config.rowWidth, config.rowSize, {
      { "  Refresh now", { color = p.cyan } },
      { "", gap = true },
      { (state.fetchedAt and ("checked " .. util.agoEpoch(state.fetchedAt))
        or "never checked") .. "  ", { color = p.faint } },
    }),
    fn = refresh,
  })
  table.insert(items, {
    title = util.row(config.rowWidth, config.rowSize,
      { { "  Open GitHub PR dashboard", { color = p.cyan } } }),
    fn = util.openURL("https://github.com/pulls"),
  })

  return items
end

function M.start()
  -- The autosave name gives the item a stable identity across restarts. It is
  -- also what a menu bar manager (Thaw, Ice, Bartender) lists it by: without
  -- one the item is anonymous, so it cannot be shown, hidden or reordered.
  menubar = hs.menubar.new(true, "hammerspoon.github_prs")
  if not menubar then return end
  menubar:setMenu(buildMenu)
  updateTitle()
  refresh()

  timer = hs.timer.doEvery(config.refreshSeconds, refresh)
  sleepWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then
      -- hs.timer is NSTimer-backed and stalls across sleep, so the repeating
      -- timer is replaced rather than trusted to pick itself back up.
      if timer then timer:stop() end
      timer = hs.timer.doEvery(config.refreshSeconds, refresh)
      refresh()
    end
  end):start()
end

-- For `hs -c "hs.inspect(menus.github.snapshot())"`.
function M.snapshot()
  local rows = {}
  for _, pr in ipairs(state.prs or {}) do
    table.insert(rows, string.format("%s #%d [%s] %s",
      pr.repository.nameWithOwner, pr.number, pr.bucket, pr.createdAt))
  end
  return { error = state.error, fetchedAt = state.fetchedAt, prs = rows }
end

function M.popup(x, y)
  if menubar then menubar:popupMenu({ x = x or 400, y = y or 40 }) end
end

function M.stop()
  if timer then timer:stop() end
  if sleepWatcher then sleepWatcher:stop() end
  if menubar then menubar:delete() end
end

return M
