-- ISSUES: THE NPCS ARE RAPING THE GOAL TOWERS
--         NPCS PHASE THROUGH EACH OTHER
--         NPCS DONT INTERACT WITH BALL PHYSICS LIKE PLAYER
--         BOY MI DEVEN KNOW

love.graphics.setDefaultFilter("nearest", "nearest")

-- Window setup
WINDOW_WIDTH = 1200
WINDOW_HEIGHT = 900
love.window.setMode(WINDOW_WIDTH, WINDOW_HEIGHT, {resizable=false, vsync=true})

-- Field dimensions
FIELD_WIDTH = WINDOW_WIDTH
FIELD_HEIGHT = WINDOW_HEIGHT

-- Deadzone to remove stick drift
local DEADZONE = 0.15

-- Robot (player)
robot = {
    width = 60,
    height = 60,
    speed = 250,
    rotation = 0,
    turnSpeed = 180, -- turning multiplier (degrees/sec-ish)
    rampFront = true, -- starts in intake position
    intakeRadius = 30,
    capacity = 3,
    holdingCount = 0,
    speedModifier = 1.0
}

rampButtonPressed = false -- for toggle detection

-- Alliance zones (left/right ends, outlined)
ALLIANCE_HEIGHT = FIELD_HEIGHT * 0.8
ALLIANCE_WIDTH = robot.width * 1.5

-- Red zone on left
redZone = {x = 0, y = (FIELD_HEIGHT - ALLIANCE_HEIGHT)/2, width = ALLIANCE_WIDTH, height = ALLIANCE_HEIGHT}
-- Blue zone on right
blueZone = {x = FIELD_WIDTH - ALLIANCE_WIDTH, y = (FIELD_HEIGHT - ALLIANCE_HEIGHT)/2, width = ALLIANCE_WIDTH, height = ALLIANCE_HEIGHT}

-- Robot starts in red zone (back touching zone, facing outward)
robot.x = redZone.x + robot.width/2
robot.y = redZone.y + redZone.height/2
robot.rotation = 0

-- Central triangle goals (3 goals at triangle vertices)
triangle = {
    {x = FIELD_WIDTH/2, y = FIELD_HEIGHT/2 - 150},
    {x = FIELD_WIDTH/2 - 150, y = FIELD_HEIGHT/2 + 100},
    {x = FIELD_WIDTH/2 + 150, y = FIELD_HEIGHT/2 + 100}
}

-- Initialize per-goal score tracker
goalScores = {}
for i=1,#triangle do goalScores[i] = 0 end

GOAL_SIZE = 60 -- normal size

-- Balls
balls = {}
ballRadius = 12
ballFriction = 400
gravity = 600
bounceLoss = 0.5

function spawnBall()
    local x = math.random(50, FIELD_WIDTH - 50)
    local y = math.random(50, FIELD_HEIGHT - 50)
    table.insert(balls, {
        x = x, y = y,
        vx = 0, vy = 0, z = 0, vz = 0,
        held = false, scored = false, holder = nil,
        targetGoal = nil,
        pickupCooldown = 0  -- immunity after release
    })
end

for i=1,15 do spawnBall() end

-- Xbox controller (if connected)
joysticks = love.joystick.getJoysticks()
joy = joysticks[1]

-- Score and Timer
score = 0
matchTime = 150  -- 2:30 -> 150 seconds
timerRunning = true
timerFont = love.graphics.newFont(70)

-- Utility functions
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function angleDiff(a, b)
    local d = (a - b + math.pi) % (2*math.pi) - math.pi
    return d
end

-- Smooth joystick curve
function applyJoystickCurve(val)
    if val == 0 then return 0 end
    local sign = val >= 0 and 1 or -1
    return sign * math.abs(val)^1.5
end

function distance(x1,y1,x2,y2)
    return ((x2-x1)^2 + (y2-y1)^2)^0.5
end

-- NPC robots
npcs = {}

function spawnNPCs()
    npcs = {}
    -- Red alliance NPCs
    local redCount = 3
    for i=1,redCount do
        local y = redZone.y + (i * (redZone.height / (redCount+1)))
        table.insert(npcs, {
            x = redZone.x + robot.width/2,
            y = y,
            width = 60, height = 60, rotation = 0,
            rampFront = true, intakeRadius = 30,
            holdingCount = 0, capacity = 3, speed = 120,
            moveTimer = 0, moveTarget = nil,
            shootTimer = 0, state = "wander",
            lockedGoal = nil, lastGoal = nil, isShooting = false,
            targetBall = nil, stuckRecover = 0
        })
    end

    -- Blue alliance NPCs
    local blueCount = 3
    for i=1,blueCount do
        local y = blueZone.y + (i * (blueZone.height / (blueCount+1)))
        table.insert(npcs, {
            x = blueZone.x + blueZone.width - robot.width/2,
            y = y,
            width = 60, height = 60, rotation = math.pi,
            rampFront = true, intakeRadius = 30,
            holdingCount = 0, capacity = 3, speed = 120,
            moveTimer = 0, moveTarget = nil,
            shootTimer = 0, state = "wander",
            lockedGoal = nil, lastGoal = nil, isShooting = false,
            targetBall = nil, stuckRecover = 0
        })
    end
end

-- spawn NPCs initially
spawnNPCs()

-- Countdown variables
countdownTime = 3       -- seconds before match starts
countdownRunning = true
matchStarted = false

-- Restart logic
function restartMatch()
    -- Reset player
    robot.x = redZone.x + robot.width/2
    robot.y = redZone.y + redZone.height/2
    robot.rotation = 0
    robot.holdingCount = 0
    robot.rampFront = true

    -- Reset NPCs
    spawnNPCs()

    -- Reset balls
    balls = {}
    for i=1,15 do spawnBall() end

    -- Reset score & timer
    score = 0
    for i=1,#goalScores do goalScores[i] = 0 end
    matchTime = 150
    timerRunning = false
    countdownTime = 3
    countdownRunning = true
    matchStarted = false
end

function love.keypressed(key)
    if key == "r" then restartMatch() end
end

-- ========================
-- Helper functions for NPC shooting & collisions (PLEASE DONT CHANGE BALL DETECT RADIUS)
-- ========================

local SHOOT_DISTANCE_AWAY = GOAL_SIZE/2 + 90
local PAUSE_BEFORE_SHOOT = 0.9
local SEPARATION_DISTANCE = 100
local TURN_SPEED = 3.0
local MOVE_SLOW_DIST = 45
local BALL_DETECT_RADIUS = 300
local MAX_SHOOT_WAIT = 2.5
local STUCK_BACK_TIME = 0.25

local function npc_release_balls(npc, goalIndex)
    if not goalIndex then return end
    local goal = triangle[goalIndex]
    if not goal then return end

    for _, b in ipairs(balls) do
        if b.held and b.holder == npc then
            b.held = false
            b.holder = nil
            b.targetGoal = goalIndex
            npc.holdingCount = math.max(0, npc.holdingCount - 1)

            -- place ball behind robot to avoid re-intake
            local backOffset = (npc.width/2 + ballRadius + 6)
            local backX = npc.x - math.cos(npc.rotation) * backOffset
            local backY = npc.y - math.sin(npc.rotation) * backOffset
            b.x, b.y = backX, backY

            -- set velocity toward goal
            local dx, dy = goal.x - backX, goal.y - backY
            local dist = math.sqrt(dx*dx + dy*dy)
            if dist == 0 then dist = 0.0001 end
            local nx, ny = dx/dist, dy/dist

            local basePower = 520
            local npcVelX = math.cos(npc.rotation) * (npc.speed or 120) * 0.2
            local npcVelY = math.sin(npc.rotation) * (npc.speed or 120) * 0.2

            b.vx = nx * basePower + npcVelX
            b.vy = ny * basePower + npcVelY
            b.vz = 220
            b.scored = false
            b.pickupCooldown = 0.25
        end
    end
end

local function chooseSmartGoal(npc)
    local bestScore = math.huge
    local bestGoal = 1
    for i, g in ipairs(triangle) do
        local score = goalScores[i] or 0
        local dist = distance(npc.x, npc.y, g.x, g.y)
        local weighted = score * 0.6 + dist * 0.4
        if weighted < bestScore then bestScore = weighted bestGoal = i end
    end
    return bestGoal
end

-- Resolve NPC-NPC overlaps by pushing each half the overlap along normal
local function resolveNpcPairCollisions()
    for i = 1, #npcs-1 do
        for j = i+1, #npcs do
            local a = npcs[i]
            local b = npcs[j]
            local dx = b.x - a.x
            local dy = b.y - a.y
            local dist = math.sqrt(dx*dx + dy*dy)
            local minDist = (a.width/2 + b.width/2) - 2 -- slight slack
            if dist < minDist and dist > 0 then
                local overlap = minDist - dist
                local nx = dx / dist
                local ny = dy / dist
                -- push each away by half the overlap
                local push = overlap * 0.5 + 0.5
                a.x = a.x - nx * push
                a.y = a.y - ny * push
                b.x = b.x + nx * push
                b.y = b.y + ny * push
            elseif dist == 0 then
                -- identical position, jitter them apart
                a.x = a.x - 0.5
                b.x = b.x + 0.5
            end
        end
    end
end

-- If an NPC overlaps a goal rectangle, push it out along shortest axis
local function resolveNpcGoalCollisions()
    for _, npc in ipairs(npcs) do
        for _, g in ipairs(triangle) do
            local left = g.x - GOAL_SIZE/2
            local right = g.x + GOAL_SIZE/2
            local top = g.y - GOAL_SIZE
            local bottom = g.y
            -- simple AABB overlap test
            if npc.x + npc.width/2 > left and npc.x - npc.width/2 < right and
               npc.y + npc.height/2 > top and npc.y - npc.height/2 < bottom then
                -- compute smallest push-out vector to escape rect
                local overlapLeft = (npc.x + npc.width/2) - left
                local overlapRight = right - (npc.x - npc.width/2)
                local overlapTop = (npc.y + npc.height/2) - top
                local overlapBottom = bottom - (npc.y - npc.height/2)
                local pushX, pushY = 0, 0
                local minOverlap = math.min(overlapLeft, overlapRight, overlapTop, overlapBottom)
                if minOverlap == overlapLeft then
                    pushX = -minOverlap - 1
                elseif minOverlap == overlapRight then
                    pushX = minOverlap + 1
                elseif minOverlap == overlapTop then
                    pushY = -minOverlap - 1
                else
                    pushY = minOverlap + 1
                end
                npc.x = npc.x + pushX
                npc.y = npc.y + pushY
                -- start stuck recovery so AI doesn't immediately drive back in
                npc.stuckRecover = STUCK_BACK_TIME
                -- small rotation nudge
                npc.rotation = npc.rotation + (math.random() - 0.5) * 0.6
            end
        end
    end
end

function love.update(dt)
    -- Countdown update
    if countdownRunning then
        countdownTime = countdownTime - dt
        if countdownTime <= 0 then
            countdownTime = 0
            countdownRunning = false
            matchStarted = true
            timerRunning = true
        end
    end

    if not matchStarted then return end

    -- Timer
    if timerRunning then
        matchTime = matchTime - dt
        if matchTime <= 0 then
            matchTime = 0
            timerRunning = false
        end
    end

    if not timerRunning then return end

    -- PLAYER CONTROLS
    local forward, turn = 0,0
    if joy then
        forward = -joy:getAxis(2)
        if math.abs(forward) < DEADZONE then forward = 0 end
        forward = applyJoystickCurve(forward)

        turn = joy:getAxis(4)
        if math.abs(turn) < DEADZONE then turn = 0 end
        turn = applyJoystickCurve(turn)

        if joy:isDown(4) then robot.speedModifier = clamp(robot.speedModifier - 0.1, 0.1, 3) end
        if joy:isDown(5) then robot.speedModifier = clamp(robot.speedModifier + 0.1, 0.1, 3) end

        if joy:isDown(2) then robot.rampFront = true end
        if joy:isDown(3) then robot.rampFront = false end
    end

    robot.rotation = robot.rotation + turn * robot.turnSpeed * dt

    if forward ~= 0 then
        local moveSpeed = robot.speed * robot.speedModifier
        robot.x = robot.x + math.cos(robot.rotation) * forward * moveSpeed * dt
        robot.y = robot.y + math.sin(robot.rotation) * forward * moveSpeed * dt
    end

    robot.x = clamp(robot.x, robot.width/2, FIELD_WIDTH - robot.width/2)
    robot.y = clamp(robot.y, robot.height/2, FIELD_HEIGHT - robot.height/2)

    -- Prevent robot entering goals (solid)
    for _, g in ipairs(triangle) do
        local left = g.x - GOAL_SIZE/2
        local right = g.x + GOAL_SIZE/2
        local top = g.y - GOAL_SIZE
        local bottom = g.y
        if robot.x + robot.width/2 > left and robot.x - robot.width/2 < right and
           robot.y + robot.height/2 > top and robot.y - robot.height/2 < bottom then
            local moveBack = 5
            robot.x = robot.x - math.cos(robot.rotation) * moveBack
            robot.y = robot.y - math.sin(robot.rotation) * moveBack
        end
    end

    -- Ramp toggle detection
    if joy then
        if joy:isDown(3) and not rampButtonPressed then
            robot.rampFront = not robot.rampFront
            rampButtonPressed = true
        elseif not joy:isDown(3) then
            rampButtonPressed = false
        end
    end

    -- PLAYER INTAKE
    if robot.rampFront then
        for _, b in ipairs(balls) do
            if not b.held and robot.holdingCount < robot.capacity and (not b.pickupCooldown or b.pickupCooldown <= 0) then
                local intakeX = robot.x + math.cos(robot.rotation) * robot.width/2
                local intakeY = robot.y + math.sin(robot.rotation) * robot.width/2
                if distance(intakeX, intakeY, b.x, b.y) < robot.intakeRadius then
                    b.held = true
                    b.holder = robot
                    robot.holdingCount = robot.holdingCount + 1
                end
            end
        end
    end

    -- PLAYER SHOOT
    if not robot.rampFront and joy and joy:isDown(2) then
        for _, b in ipairs(balls) do
            if b.held and b.holder == robot then
                b.held = false
                b.holder = nil
                robot.holdingCount = math.max(0, robot.holdingCount - 1)
                local shootPower = 400
                local backX = robot.x - math.cos(robot.rotation) * robot.width/2
                local backY = robot.y - math.sin(robot.rotation) * robot.width/2
                b.x = backX
                b.y = backY
                b.vx = -math.cos(robot.rotation) * shootPower
                b.vy = -math.sin(robot.rotation) * shootPower
                b.vz = 200
                b.scored = false
                b.pickupCooldown = 0.25
            end
        end
    end

    -- BALL PHYSICS
    for _, b in ipairs(balls) do
        if b.held then
            if b.holder then
                b.x = b.holder.x
                b.y = b.holder.y
            end
            b.z = 0
            b.vz = 0
        else
            -- horizontal motion
            b.x = b.x + b.vx * dt
            b.y = b.y + b.vy * dt

            -- friction
            local speed = math.sqrt(b.vx*b.vx + b.vy*b.vy)
            if speed > 0 then
                local frictionEffect = ballFriction * dt
                if frictionEffect > speed then frictionEffect = speed end
                b.vx = b.vx - (b.vx / speed) * frictionEffect
                b.vy = b.vy - (b.vy / speed) * frictionEffect
            end

            -- vertical motion (bounce simulation)
            b.vz = b.vz - gravity * dt
            b.z = b.z + b.vz * dt
            if b.z < 0 then
                b.z = 0
                b.vz = -b.vz * bounceLoss
            end

            -- decrement pickup cooldown
            if b.pickupCooldown and b.pickupCooldown > 0 then
                b.pickupCooldown = b.pickupCooldown - dt
                if b.pickupCooldown < 0 then b.pickupCooldown = 0 end
            end

            -- Ball-robot collision (simple impulse) — player
            local dx = b.x - robot.x
            local dy = b.y - robot.y
            local dist = math.sqrt(dx*dx + dy*dy)
            local minDist = robot.width/2 + ballRadius
            if dist < minDist and dist > 0 then
                local overlap = minDist - dist
                local nx, ny = dx/dist, dy/dist
                b.x = b.x + nx * overlap
                b.y = b.y + ny * overlap
                local robotVelX = math.cos(robot.rotation) * forward * robot.speed * robot.speedModifier
                local robotVelY = math.sin(robot.rotation) * forward * robot.speed * robot.speedModifier
                local dot = robotVelX * nx + robotVelY * ny
                b.vx = b.vx + nx * dot
                b.vy = b.vy + ny * dot
            end
        end
    end

    -- Scoring (single, authoritative pass)
    for _, b in ipairs(balls) do
        if not b.held and not b.scored and math.abs(b.vz) < 1 then
            for gi, g in ipairs(triangle) do
                local gx, gy = g.x, g.y
                if b.x > gx - GOAL_SIZE/2 and b.x < gx + GOAL_SIZE/2 and
                   b.y > gy - GOAL_SIZE and b.y < gy then
                    -- mark scored once and update counters
                    b.scored = true
                    score = score + 1
                    if b.targetGoal and goalScores[b.targetGoal] ~= nil then
                        goalScores[b.targetGoal] = goalScores[b.targetGoal] + 1
                        b.targetGoal = nil
                    else
                        goalScores[gi] = goalScores[gi] + 1
                    end
                    -- respawn ball
                    b.x = math.random(50, FIELD_WIDTH - 50)
                    b.y = math.random(50, FIELD_HEIGHT - 50)
                    b.vx, b.vy, b.vz, b.z = 0,0,0,0
                    b.pickupCooldown = 0
                end
            end
        end
    end

    -- ========================
    -- NPC AI (GOD HELP US)
    -- ========================
    for i, npc in ipairs(npcs) do
        -- initialize safe fields
        npc.state = npc.state or "wander"
        npc.shootTimer = npc.shootTimer or 0
        npc.shootWait = npc.shootWait or 0
        npc.lockedGoal = npc.lockedGoal or nil
        npc.moveTimer = npc.moveTimer or 0
        npc.moveTarget = npc.moveTarget or nil
        npc.targetBall = npc.targetBall or nil
        npc.lastGoal = npc.lastGoal or nil
        npc.stuckRecover = npc.stuckRecover or 0

        -- ---------- separation steering (nudge) ----------
        local steerX, steerY = 0, 0
        local neighbors = 0
        for j, other in ipairs(npcs) do
            if i ~= j then
                local dx, dy = other.x - npc.x, other.y - npc.y
                local dist = math.sqrt(dx*dx + dy*dy)
                if dist < SEPARATION_DISTANCE and dist > 0 then
                    local push = (SEPARATION_DISTANCE - dist) / SEPARATION_DISTANCE
                    steerX = steerX - (dx / dist) * push
                    steerY = steerY - (dy / dist) * push
                    neighbors = neighbors + 1
                end
            end
        end
        -- avoid player
        local pdx, pdy = robot.x - npc.x, robot.y - npc.y
        local pdist = math.sqrt(pdx*pdx + pdy*pdy)
        local pAvoidDist = SEPARATION_DISTANCE - 12
        if pdist < pAvoidDist and pdist > 0 then
            steerX = steerX - (pdx / pdist) * ((pAvoidDist - pdist) / pAvoidDist)
            steerY = steerY - (pdy / pdist) * ((pAvoidDist - pdist) / pAvoidDist)
            neighbors = neighbors + 1
        end
        if neighbors > 0 then
            steerX = steerX / neighbors
            steerY = steerY / neighbors
        end

        -- If in stuck recovery, back out and skip normal AI
        if npc.stuckRecover and npc.stuckRecover > 0 then
            local backSpeed = (npc.speed or 120) * 0.7
            npc.x = npc.x - math.cos(npc.rotation) * backSpeed * dt
            npc.y = npc.y - math.sin(npc.rotation) * backSpeed * dt
            npc.stuckRecover = npc.stuckRecover - dt
            npc.rotation = npc.rotation + (math.random() - 0.5) * 0.4 * dt
            goto afterNPCAI
        end

        -- ---------- state machine ----------
        if npc.state == "wander" then
            npc.rampFront = true
            npc.targetBall = nil

            if not npc.moveTarget or npc.moveTimer <= 0 then
                npc.moveTarget = { x = math.random(120, FIELD_WIDTH - 120), y = math.random(120, FIELD_HEIGHT - 120) }
                npc.moveTimer = 1.8 + math.random() * 2.8
            else
                npc.moveTimer = npc.moveTimer - dt
            end

            npc.rotation = npc.rotation + (math.random() - 0.5) * 0.25 * dt

            -- find nearest free ball
            local nearestBall, nbDist = nil, math.huge
            for _, b in ipairs(balls) do
                if not b.held then
                    local d = distance(npc.x, npc.y, b.x, b.y)
                    if d < nbDist then
                        nbDist = d
                        nearestBall = b
                    end
                end
            end
            if nearestBall and nbDist < BALL_DETECT_RADIUS then
                npc.state = "collect"
                npc.targetBall = nearestBall
            end

            -- move toward wander target with steering
            if npc.moveTarget then
                local desiredAngle = math.atan2(npc.moveTarget.y - npc.y, npc.moveTarget.x - npc.x)
                if steerX ~= 0 or steerY ~= 0 then
                    local steerAngle = math.atan2(steerY, steerX)
                    desiredAngle = desiredAngle + angleDiff(steerAngle, desiredAngle) * 0.22
                end
                npc.rotation = npc.rotation + angleDiff(desiredAngle, npc.rotation) * dt * TURN_SPEED
                local moveDist = distance(npc.x, npc.y, npc.moveTarget.x, npc.moveTarget.y)
                local speedMod = moveDist < MOVE_SLOW_DIST and 0.45 or 1.0
                local moveSpeed = (npc.speed or 120) * speedMod * dt
                npc.x = npc.x + math.cos(npc.rotation) * moveSpeed
                npc.y = npc.y + math.sin(npc.rotation) * moveSpeed
            end

        elseif npc.state == "collect" then
            npc.rampFront = true
            if not npc.targetBall or npc.targetBall.held then
                npc.state = "wander"
                npc.targetBall = nil
            else
                local desired = math.atan2(npc.targetBall.y - npc.y, npc.targetBall.x - npc.x)
                if steerX ~= 0 or steerY ~= 0 then
                    local steerAngle = math.atan2(steerY, steerX)
                    desired = desired + angleDiff(steerAngle, desired) * 0.25
                end
                npc.rotation = npc.rotation + angleDiff(desired, npc.rotation) * dt * TURN_SPEED

                local distToBall = distance(npc.x, npc.y, npc.targetBall.x, npc.targetBall.y)
                local speedMod = distToBall < MOVE_SLOW_DIST and 0.5 or 1.0
                local moveSpeed = (npc.speed or 120) * speedMod * dt
                npc.x = npc.x + math.cos(npc.rotation) * moveSpeed
                npc.y = npc.y + math.sin(npc.rotation) * moveSpeed

                -- collect if intake touches ball AND cooldown expired
                local intakeX = npc.x + math.cos(npc.rotation) * npc.width/2
                local intakeY = npc.y + math.sin(npc.rotation) * npc.width/2
                if distance(intakeX, intakeY, npc.targetBall.x, npc.targetBall.y) < npc.intakeRadius
                   and not npc.targetBall.held and npc.holdingCount < npc.capacity
                   and (not npc.targetBall.pickupCooldown or npc.targetBall.pickupCooldown <= 0) then
                    npc.targetBall.held = true
                    npc.targetBall.holder = npc
                    npc.holdingCount = npc.holdingCount + 1
                    npc.lockedGoal = chooseSmartGoal(npc)
                    npc.state = "aim"
                    npc.shootTimer = PAUSE_BEFORE_SHOOT
                    npc.shootWait = 0
                end
            end

        elseif npc.state == "aim" then
            npc.rampFront = false
            if not npc.lockedGoal then npc.lockedGoal = chooseSmartGoal(npc) end
            local goal = triangle[npc.lockedGoal]
            if goal then
                local angleToGoal = math.atan2(goal.y - npc.y, goal.x - npc.x)
                local targetX = goal.x - math.cos(angleToGoal) * SHOOT_DISTANCE_AWAY
                local targetY = goal.y - math.sin(angleToGoal) * SHOOT_DISTANCE_AWAY

                local desiredAngle = math.atan2(targetY - npc.y, targetX - npc.x)
                if steerX ~= 0 or steerY ~= 0 then
                    local steerAngle = math.atan2(steerY, steerX)
                    desiredAngle = desiredAngle + angleDiff(steerAngle, desiredAngle) * 0.22
                end
                npc.rotation = npc.rotation + angleDiff(desiredAngle, npc.rotation) * dt * TURN_SPEED

                local distToTarget = distance(npc.x, npc.y, targetX, targetY)
                local speedMod = distToTarget < MOVE_SLOW_DIST and 0.45 or 1.0
                local moveSpeed = (npc.speed or 120) * speedMod * dt
                npc.x = npc.x + math.cos(npc.rotation) * moveSpeed
                npc.y = npc.y + math.sin(npc.rotation) * moveSpeed

                if distToTarget <= 12 then
                    npc.state = "pauseToShoot"
                    npc.shootTimer = PAUSE_BEFORE_SHOOT
                    npc.shootWait = 0
                else
                    npc.shootWait = (npc.shootWait or 0) + dt
                    if npc.shootWait >= MAX_SHOOT_WAIT and npc.holdingCount > 0 then
                        npc_release_balls(npc, npc.lockedGoal)
                        npc.lastGoal = npc.lockedGoal
                        npc.lockedGoal = nil
                        npc.state = "wander"
                        npc.shootTimer = math.random(1,2)
                        npc.shootWait = 0
                    end
                end
            else
                npc.state = "wander"
                npc.lockedGoal = nil
            end

        elseif npc.state == "pauseToShoot" then
            npc.rampFront = false
            local goal = triangle[npc.lockedGoal]
            if goal then
                local aimAngle = math.atan2(goal.y - npc.y, goal.x - npc.x)
                npc.rotation = npc.rotation + angleDiff(aimAngle, npc.rotation) * dt * 3
            end

            npc.shootTimer = npc.shootTimer - dt
            npc.shootWait = (npc.shootWait or 0) + dt
            if npc.shootTimer <= 0 or (npc.shootWait >= MAX_SHOOT_WAIT) then
                npc_release_balls(npc, npc.lockedGoal)
                npc.lastGoal = npc.lockedGoal
                npc.lockedGoal = nil
                npc.state = "wander"
                npc.shootTimer = math.random(1,2)
                npc.shootWait = 0
            end
        end

        ::afterNPCAI::
    end

    -- post-AI corrections: resolve pair collisions and goal overlaps
    resolveNpcPairCollisions()
    resolveNpcGoalCollisions()

    -- ensure NPCs stay inside field
    for _, npc in ipairs(npcs) do
        npc.x = clamp(npc.x, npc.width/2, FIELD_WIDTH - npc.width/2)
        npc.y = clamp(npc.y, npc.height/2, FIELD_HEIGHT - npc.height/2)
    end
end

-- Draw
function love.draw()
    -- Field background
    love.graphics.setColor(0.2,0.2,0.2)
    love.graphics.rectangle("fill", 0, 0, FIELD_WIDTH, FIELD_HEIGHT)

    -- Alliance zones (outlined left/right)
    love.graphics.setColor(1,0,0)
    love.graphics.rectangle("line", redZone.x, redZone.y, redZone.width, redZone.height)
    love.graphics.setColor(0,0,1)
    love.graphics.rectangle("line", blueZone.x, blueZone.y, blueZone.width, blueZone.height)

    -- Triangle goals outline
    love.graphics.setColor(1,1,0)
    love.graphics.polygon("line", triangle[1].x, triangle[1].y, triangle[2].x, triangle[2].y, triangle[3].x, triangle[3].y)

    -- Goals (filled white rectangles at vertices)
    for _, v in ipairs(triangle) do
        love.graphics.setColor(1,1,1)
        love.graphics.rectangle("fill", v.x - GOAL_SIZE/2, v.y - GOAL_SIZE, GOAL_SIZE, GOAL_SIZE)
    end

    -- Draw goal score
    love.graphics.setFont(love.graphics.newFont(30))
    for i, g in ipairs(triangle) do
        love.graphics.setColor(1,1,1)
        love.graphics.printf(tostring(goalScores[i]), g.x - 15, g.y - GOAL_SIZE - 40, 30, "center")
    end

    -- NPC robots
    for _, npc in ipairs(npcs) do
        love.graphics.push()
        love.graphics.translate(npc.x, npc.y)
        love.graphics.rotate(npc.rotation)
        if npc.x < FIELD_WIDTH/2 then
            love.graphics.setColor(1,0,0)
        else
            love.graphics.setColor(0,0,1)
        end
        love.graphics.rectangle("fill", -npc.width/2, -npc.height/2, npc.width, npc.height)
        -- ramp
        love.graphics.setColor(1,1,0)
        local rampThickness = 8
        local rampOffset = npc.rampFront and (npc.width/2 - rampThickness/2) or (-rampThickness/2)
        love.graphics.rectangle("fill", rampOffset, -npc.height/2, rampThickness, npc.height)
        love.graphics.pop()
    end

    -- Player robot
    love.graphics.setColor(0,0,1)
    love.graphics.push()
    love.graphics.translate(robot.x, robot.y)
    love.graphics.rotate(robot.rotation)
    love.graphics.rectangle("fill", -robot.width/2, -robot.height/2, robot.width, robot.height)
    -- Front indicator (red)
    love.graphics.setColor(1,0,0)
    love.graphics.polygon("fill", robot.width/2, -robot.height/4, robot.width/2, robot.height/4, robot.width/2 + 15, 0)
    -- Ramp (red)
    love.graphics.setColor(1,0,0)
    local rampThickness = 8
    local rampOffset = robot.rampFront and (robot.width/2 - rampThickness/2) or (-rampThickness/2)
    love.graphics.rectangle("fill", rampOffset, -robot.height/2, rampThickness, robot.height)
    -- Facing line (yellow)
    love.graphics.setColor(1,1,0)
    love.graphics.setLineWidth(2)
    love.graphics.line(0,0, robot.width/2 + 15, 0)
    love.graphics.pop()

    -- Balls
    for _, b in ipairs(balls) do
        love.graphics.setColor(0,1,0)
        love.graphics.circle("fill", b.x, b.y - b.z, ballRadius)
    end

    -- Countdown
    if countdownRunning then
        love.graphics.setFont(love.graphics.newFont(100))
        love.graphics.setColor(1,1,0)
        love.graphics.printf(math.ceil(countdownTime), 0, WINDOW_HEIGHT/2 - 50, WINDOW_WIDTH, "center")
    end

    -- Timer
    love.graphics.setFont(timerFont)
    local minutes = math.floor(matchTime/60)
    local seconds = math.floor(matchTime%60)
    local timeStr = string.format("%02d:%02d", minutes, seconds)
    love.graphics.setColor(1,1,1)
    love.graphics.printf(timeStr, 0, 20, WINDOW_WIDTH, "center")

    -- Score
    love.graphics.setFont(love.graphics.newFont(30))
    love.graphics.printf("Score: "..score, 0, 120, WINDOW_WIDTH, "center")
end
