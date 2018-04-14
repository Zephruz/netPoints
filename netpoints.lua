--[[
	netPoint - V1

	-- What does this do?
		* Provides a means of data transferring/querying between the client and server
		* Performs (mostly) like Ajax

	TODO:
		- Handshakes between client & server (to verify that the data is supposed to be transferred at the time of request)
]]

netPoint = (netPoint or {})

--[[CONFIG]]
netPoint.debug = false 		-- Enables debug messages

netPoint.reqTimeout = 5  	-- How long before a request times out and retries

netPoint.reqRetryAmt = 3	-- How many times a request is retried before closed

netPoint.maxRequests = 100 -- Maximum amount of requests within 5 seconds [before a user gets blocked from sending more until timeout]

--[[DON'T EDIT BELOW HERE]]
netPoint._cache = (netPoint._cache or {})
netPoint._endPoints = (netPoint._endPoints or {})
netPoint._receivers = {
	["cl"] = "NP.RC",
	["sv"] = "NP.RS",
}

--[[----------
	SHARED
------------]]

---------------------
--> netPoint:DebugMessage(...)
-- 	-> Prints a message to console if debug mode is enabled.
-- 	-> Used for debugging.
--  -> ARGUMENTS
	-- Works the same as MsgC()
---------------------
function netPoint:DebugMessage(...)
	if !(self.debug) then return false end

	local pfx = (CLIENT && "CLIENT" || "SERVER")

	MsgC(Color(255,255,0), "[NP - " .. pfx .. "] ", Color(255,255,255), ..., "\n")
end

---------------------
--> netPoint:GetEndPoint(reqEP)
-- 	-> Retrieves an EndPoint
--  -> ARGUMENTS
	-- * reqEP (STRING) - EndPoint name
---------------------
function netPoint:GetEndPoint(reqEP)
	return (self._endPoints && self._endPoints[reqEP] || nil)
end

---------------------
--> netPoint:RemoveEndPoint(reqEP)
-- 	-> Removes an EndPoint
--  -> ARGUMENTS
	-- * reqEP (STRING) - EndPoint name
---------------------
function netPoint:RemoveEndPoint(reqEP)
	self._endPoints[reqEP] = nil -- Just nil it
end

---------------------
--> netPoint:CreateEndPoint(reqEP, data)
-- 	-> Creates an EndPoint
--  -> ARGUMENTS
	-- * reqEP (STRING) - EndPoint name
	-- * data (TABLE) - EndPoint data/configuration
---------------------
function netPoint:CreateEndPoint(reqEP, data)
	if !(self._endPoints) then self._endPoints = {} end

	self._endPoints[reqEP] = data
end

---------------------
--> netPoint:CompressTableToSend(tbl)
-- 	-> Compresses a table and returns the compressed data and the length of the data
--  -> ARGUMENTS
	-- * tbl (TABLE) - Data table to compress
---------------------
function netPoint:CompressTableToSend(tbl)
	tbl = (von && von.serialize(tbl) || util.TableToJSON(tbl))
	tbl = util.Compress(tbl)

	if !(tbl) then return self:CompressTableToSend({["_netPoint"] = "NO DATA [empty]"}) end

	return tbl, (tbl && #tbl || 0)
end

---------------------
--> netPoint:DecompressNetData()
-- 	-> Decompresses received net data.
--	-> Must be used within a net.Receive callback and data must be sent with netPoint:SendCompressedNetMessage(...)
--		-> You can also use netPoint:CompressTableToSend(...) to compress data and send it yourself
---------------------
function netPoint:DecompressNetData()
	local dataBInt = net.ReadUInt(32)
	local data = net.ReadData(dataBInt)
	data = (data && util.Decompress(data))
	data = (data && von && von.deserialize(data) || data && util.JSONToTable(data) || nil)

	if (data["_netPoint"]) then
		self:DebugMessage(data["_netPoint"])

		data["_netPoint"] = nil
	end

	return data, dataBInt
end

---------------------
--> netPoint:SendCompressedNetMessage(nwuid, receiver, data, cbWrite)
-- 	-> Sends a compressed net message
	-- * nwuid (STRING) - EndPoint name
	-- * receiver (ENTITY OR TABLE OR STRING) - Receiver. Must be a player, table of players, or "SERVER"
	-- * data (TABLE) - Message data
	-- * cbWrite (FUNCTION) - Optional argument to append more data to the net message
---------------------
function netPoint:SendCompressedNetMessage(nwuid, receiver, data, cbWrite)
	local compData, compBInt = self:CompressTableToSend(data)

	if (compData && compBInt) then
		net.Start(nwuid)
			net.WriteUInt(compBInt, 32)
			net.WriteData(compData, compBInt)
			if (isfunction(cbWrite)) then cbWrite() end
		if (receiver == "SERVER") then
			net.SendToServer()
		else
			net.Send(receiver)
		end
	end
end

--[[
	SERVER
]]
if (SERVER) then
	util.AddNetworkString(netPoint._receivers["sv"])
	util.AddNetworkString(netPoint._receivers["cl"])

	--[[Used to receive netpoint requests]]
	net.Receive(netPoint._receivers["sv"],
	function(len,ply)
		if !(IsValid(ply)) then return false end

		-- Check if this player is spamming, if so; stop them (temporarily)
		local maxReqs = (netPoint.maxRequests or 100)
		local rfsResAt = ply:GetNWInt("NP_RS_RESETAT", os.time())
		local rfsTReqs = ply:GetNWInt("NP_RS_TOTAL", 1)

		if (rfsResAt > os.time() && rfsTReqs >= maxReqs) then
			return false
		elseif (rfsResAt < os.time()) then
			ply:SetNWInt("NP_RS_RESETAT", os.time()+5)
			ply:SetNWInt("NP_RS_TOTAL", 0)
		else
			ply:SetNWInt("NP_RS_TOTAL", rfsTReqs+1)
		end

		local retData = {}
		local reqData, reqDataBInt = netPoint:DecompressNetData()
		local reqEPRec = net.ReadString()
		local reqIDRec = net.ReadString()

		local epData = netPoint:GetEndPoint(reqEPRec)

		if !(epData) then return false end	-- This should not happen; this message got sent to the wrong endpoint or this user is attempting an exploit
		if (!reqData or reqData["_CLERR"] or !reqEPRec or !reqIDRec) then return false end

		for k,v in pairs(epData) do
			local val = reqData[k]

			if (val) then
				retData[k] = (v(ply,val) or {})
			end
		end

		if !(retData) then return false end

		netPoint:SendCompressedNetMessage(netPoint._receivers["cl"], ply, retData,
			function()
				net.WriteString(reqEPRec)
				net.WriteString(reqIDRec)
			end)
	end)
end

--[[
	CLIENT
]]
if (CLIENT) then
	netPoint._openRequests = (netPoint._openRequests or {})

	--[[Used to receive netpoint messages]]
	net.Receive(netPoint._receivers["cl"],
	function(len)
		local dataRes, dataBInt = netPoint:DecompressNetData()
		local nmReqEP = net.ReadString()
		local nmReqID = net.ReadString()

		if (!dataRes or !nmReqEP or !nmReqID) then return end

		local epData = netPoint:GetEndPoint(nmReqEP)
		local data = netPoint:GetRequest(nmReqID)
		data = (data && data.data)

		if (epData && data) then
			-- Add to cache
			netPoint._cache[nmReqID] = (netPoint._cache[nmReqID] or {})
			table.insert(netPoint._cache[nmReqID], {
				params = data,
				result = dataRes,
			})

			-- Run receive results callback
			if (data.receiveResults) then
				data.receiveResults(dataRes)
			end

			netPoint:RemoveRequest(nmReqID)	-- Close the request

			netPoint:DebugMessage("RESULT RECEIVED: " .. nmReqID .. " (SIZE: " .. (dataBInt || "NIL") .. " bytes)" .. " - " .. os.date("%H:%M:%S - %m/%d/%Y", os.time()))
		end
	end)

	---------------------
	--> netPoint:RemoveRequest(reqID)
	-- 	-> Returns the specified request or nil if invalid
	--  -> ARGUMENTS
		-- * reqID (STRING) - Unique request name/ID
	---------------------
	function netPoint:GetRequest(reqID)
		return (self._openRequests[reqID] or nil)
	end

	---------------------
	--> netPoint:RemoveRequest(reqID)
	-- 	-> Removes the specified request
	--  -> ARGUMENTS
		-- * reqID (STRING) - Unique request name/ID
	---------------------
	function netPoint:RemoveRequest(reqID)
		self._openRequests[reqID] = nil
	end

	---------------------
	--> netPoint:FromEndPoint(reqEP, reqID, data, retAmt (NIL))
	-- 	-> Requests data from the specified endpoint
	--  -> ARGUMENTS
		-- * reqEP (STRING) - EndPoint name
		-- * retID (STRING) - EndPoint unique request name
		-- * data (TABLE) - EndPoint data/configuration
		-- * retAmt (INTEGER) - This is handled in the function automatically
	---------------------
	function netPoint:FromEndPoint(reqEP, reqID, data, retAmt)
		self._openRequests = (self._openRequests or {})

		local function openRequest(reqEP, data)
			local reqData = (data.requestData || {["_CLERR"] = "[NETPOINT] CLIENT REQUEST ERROR: `data.requestData` invalid \n\treqEP: " .. (reqEP or "NIL")})

			-- Send request
			self:SendCompressedNetMessage(netPoint._receivers["sv"], "SERVER", reqData,
				function()
					net.WriteString(reqEP)
					net.WriteString(tostring(reqID))
				end)

			self:DebugMessage("REQUEST SENT: " .. reqID .. " - " .. os.date("%H:%M:%S - %m/%d/%Y", os.time()))
		end

		local function openListener(reqEP, data)
			local reqTime = CurTime()

			self._openRequests[reqID] = {
				data = data,
				time = reqTime,
			}

			timer.Simple(self.reqTimeout,
			function()
				local req = self:GetRequest(reqID)

				if (req && req.time == reqTime) then
					retAmt = (retAmt && retAmt + 1 or 1)

					self:DebugMessage("RESULT TIMED OUT: " .. reqID .. " (RETRYING - " .. retAmt .. " of " .. self.reqRetryAmt .. ") - " .. os.date("%H:%M:%S - %m/%d/%Y", os.time()))

					self:FromEndPoint(reqEP, reqID, data, retAmt)	-- Retry (Probably dropped/not received)
				end
			end)
		end

		if (retAmt && retAmt >= self.reqRetryAmt) then self:RemoveRequest(reqID) return false end

		openListener(reqEP, data)	-- Open our listener
		openRequest(reqEP, data)	-- Start our request
	end
end
