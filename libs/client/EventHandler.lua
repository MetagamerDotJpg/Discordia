local enums = require('enums')

local channelType = enums.channelType
local concat, insert = table.concat, table.insert

local function warning(client, object, id, event)
	return client:warning('Uncached %s (%s) on %s', object, id, event)
end

local function checkReady(shard)
	for _, v in pairs(shard._loading) do
		if next(v) then return end
	end
	shard._ready = true
	shard._loading = nil
	local client = shard._client
	client:emit('shardReady', shard._id)
	for _, other in pairs(client._shards) do
		if not other._ready then return end
	end
	collectgarbage()
	return client:emit('ready')
end

local function getChannel(client, id)
	local guild = client._channel_map[id]
	if guild then
		return guild._text_channels:get(id)
	else
		return client._private_channels:get(id) or client._group_channels:get(id)
	end
end

local EventHandler = setmetatable({}, {__index = function(self, k)
	self[k] = function(_, _, shard)
		return shard:warning('Unhandled gateway event: %s', k)
	end
	return self[k]
end})

function EventHandler.READY(d, client, shard)

	-- TODO: relationships (maybe)

	shard:info('Received READY (%s)', concat(d._trace, ', '))
	shard:emit('READY')

	shard._session_id = d.session_id
	client._user = client._users:_insert(d.user)

	local guilds = client._guilds
	local group_channels = client._group_channels
	local private_channels = client._private_channels

	for _, channel in ipairs(d.private_channels) do
		if channel.type == channelType.private then
			private_channels:_insert(channel)
		elseif channel.type == channelType.group then
			group_channels:_insert(channel)
		end
	end

	local loading = shard._loading

	if d.user.bot then
		for _, guild in ipairs(d.guilds) do
			guilds:_insert(guild)
			loading.guilds[guild.id] = true
		end
	else
		if client._options.syncGuilds then
			local ids = {}
			for _, guild in ipairs(d.guilds) do
				guilds:_insert(guild)
				if not guild.unavailable then -- if available
					loading.syncs[guild.id] = true
					insert(ids, guild.id)
				end
			end
			shard:syncGuilds(ids)
		else
			guilds:_load(d.guilds)
		end
	end

	return checkReady(shard)

end

function EventHandler.RESUMED(d, client, shard)
	shard:info('Received RESUMED (%s)', concat(d._trace, ', '))
	return client:emit('shardResumed', shard._id)
end

function EventHandler.GUILD_MEMBERS_CHUNK(d, client, shard)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_MEMBERS_CHUNK') end
	guild._members:_load(d.members)
	if shard._loading and guild._member_count == #guild._members then
		shard._loading.chunks[d.guild_id] = nil
		return checkReady(shard)
	end
end

function EventHandler.GUILD_SYNC(d, client, shard)
	local guild = client._guilds:get(d.id)
	if not guild then return warning(client, 'Guild', d.id, 'GUILD_SYNC') end
	guild._large = d.large
	guild:_loadMembers(d, shard)
	if shard._loading then
		shard._loading.syncs[d.id] = nil
		return checkReady(shard)
	end
end

function EventHandler.CHANNEL_CREATE(d, client)
	local channel
	if d.type == channelType.text then
		local guild = client._guilds:get(d.guild_id)
		if not guild then return warning(client, 'Guild', d.guild_id, 'CHANNEL_CREATE') end
		channel = guild._text_channels:_insert(d)
	elseif d.type == channelType.voice then
		local guild = client._guilds:get(d.guild_id)
		if not guild then return warning(client, 'Guild', d.guild_id, 'CHANNEL_CREATE') end
		channel = guild._voice_channels:_insert(d)
	elseif d.type == channelType.private then
		channel = client._private_channels:_insert(d)
	elseif d.type == channelType.group then
		channel = client._group_channels:_insert(d)
	else
		return client:warning('Unhandled CHANNEL_CREATE (type %s)', d.type)
	end
	return client:emit('channelCreate', channel)
end

function EventHandler.CHANNEL_UPDATE(d, client)
	local channel
	if d.type == channelType.text then
		local guild = client._guilds:get(d.guild_id)
		if not guild then return warning(client, 'Guild', d.guild_id, 'CHANNEL_UPDATE') end
		channel = guild._text_channels:_insert(d)
	elseif d.type == channelType.voice then
		local guild = client._guilds:get(d.guild_id)
		if not guild then return warning(client, 'Guild', d.guild_id, 'CHANNEL_UPDATE') end
		channel = guild._voice_channels:_insert(d)
	-- elseif d.type == channelType.private then -- private channels should never update
		-- channel = client._private_channels:_insert(d)
	elseif d.type == channelType.group then
		channel = client._group_channels:_insert(d)
	else
		return client:warning('Unhandled CHANNEL_UPDATE (type %s)', d.type)
	end
	return client:emit('channelUpdate', channel)
end

function EventHandler.CHANNEL_DELETE(d, client)
	local channel
	if d.type == channelType.text then
		local guild = client._guilds:get(d.guild_id)
		if not guild then return warning(client, 'Guild', d.guild_id, 'CHANNEL_DELETE') end
		channel = guild._text_channels:_remove(d)
	elseif d.type == channelType.voice then
		local guild = client._guilds:get(d.guild_id)
		if not guild then return warning(client, 'Guild', d.guild_id, 'CHANNEL_DELETE') end
		channel = guild._voice_channels:_remove(d)
	elseif d.type == channelType.private then
		channel = client._private_channels:_remove(d)
	elseif d.type == channelType.group then
		channel = client._group_channels:_remove(d)
	else
		return client:warning('Unhandled CHANNEL_DELETE (type %s)', d.type)
	end
	return client:emit('channelDelete', channel)
end

function EventHandler.CHANNEL_RECIPIENT_ADD(d, client)
	local channel = client._group_channels:get(d.channel_id)
	if not channel then return warning(client, 'GroupChannel', d.channel_id, 'CHANNEL_RECIPIENT_ADD') end
	local user = channel._recipients:_insert(d.user)
	return client:emit('recipientAdd', channel, user)
end

function EventHandler.CHANNEL_RECIPIENT_REMOVE(d, client)
	local channel = client._group_channels:get(d.channel_id)
	if not channel then return warning(client, 'GroupChannel', d.channel_id, 'CHANNEL_RECIPIENT_ADD') end
	local user = channel._recipients:_remove(d.user)
	return client:emit('recipientRemove', channel, user)
end

function EventHandler.GUILD_CREATE(d, client, shard)
	if client._options.syncGuilds and not d.unavailable and not client._user._bot then
		shard:syncGuilds({d.id})
	end
	local guild = client._guilds:get(d.id)
	if guild then
		if guild._unavailable and not d.unavailable then
			guild:_load(d) -- do guilds mutate while unavailable?
			guild:_makeAvailable(d)
			client:emit('guildAvailable', guild)
		end
		if shard._loading then
			shard._loading.guilds[d.id] = nil
			return checkReady(shard)
		end
	else
		guild = client._guilds:_insert(d)
		return client:emit('guildCreate', guild)
	end
end

function EventHandler.GUILD_UPDATE(d, client)
	local guild = client._guilds:_insert(d)
	return client:emit('guildUpdate', guild)
end

function EventHandler.GUILD_DELETE(d, client)
	if d.unavailable then
		local guild = client._guilds:_insert(d)
		return client:emit('guildUnavailable', guild)
	else
		local guild = client._guilds:_remove(d)
		return client:emit('guildDelete', guild)
	end
end

function EventHandler.GUILD_BAN_ADD(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_BAN_ADD') end
	local user = client._users:_insert(d.user)
	return client:emit('userBan', user, guild)
end

function EventHandler.GUILD_BAN_REMOVE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_BAN_REMOVE') end
	local user = client._users:_insert(d.user)
	return client:emit('userUnban', user, guild)
end

function EventHandler.GUILD_EMOJIS_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_EMOJIS_UPDATE') end
	guild._emojis:_load(d.emojis, true)
	return client:emit('emojisUpdate', guild)
end

function EventHandler.GUILD_MEMBER_ADD(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_MEMBER_ADD') end
	local member = guild._members:_insert(d)
	guild._member_count = guild._member_count + 1
	return client:emit('memberJoin', member)
end

function EventHandler.GUILD_MEMBER_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_MEMBER_UPDATE') end
	local member = guild._members:_insert(d)
	return client:emit('memberUpdate', member)
end

function EventHandler.GUILD_MEMBER_REMOVE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_MEMBER_REMOVE') end
	local member = guild._members:_remove(d)
	guild._member_count = guild._member_count - 1
	return client:emit('memberLeave', member)
end

function EventHandler.GUILD_ROLE_CREATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_ROLE_CREATE') end
	local role = guild._roles:_insert(d.role)
	return client:emit('roleCreate', role)
end

function EventHandler.GUILD_ROLE_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_ROLE_UPDATE') end
	local role = guild._roles:_insert(d.role)
	return client:emit('roleUpdate', role)
end

function EventHandler.GUILD_ROLE_DELETE(d, client) -- role object not provided
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'GUILD_ROLE_DELETE') end
	local role = guild._roles:_delete(d.role_id)
	if not role then return warning(client, 'Role', d.role_id, 'GUILD_ROLE_DELETE') end
	return client:emit('roleDelete', role)
end

function EventHandler.MESSAGE_CREATE(d, client)
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_CREATE') end
	local message = channel._messages:_insert(d)
	return client:emit('messageCreate', message)
end

function EventHandler.MESSAGE_UPDATE(d, client) -- may not contain the whole message
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_UPDATE') end
	local message = channel._messages:get(d.id)
	if message then
		message:_load(d)
		return client:emit('messageUpdate', message)
	else
		return client:emit('messageUpdateUncached', channel, d.id)
	end
end

function EventHandler.MESSAGE_DELETE(d, client) -- message object not provided
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_DELETE') end
	local message = channel._messages:_delete(d.id)
	if message then
		return client:emit('messageDelete', message)
	else
		return client:emit('messageDeleteUncached', channel, d.id)
	end
end

function EventHandler.MESSAGE_DELETE_BULK(d, client)
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_DELETE_BULK') end
	for _, id in ipairs(d.ids) do
		local message = channel._messages:_delete(id)
		if message then
			client:emit('messageDelete', message)
		else
			client:emit('messageDeleteUncached', channel, id)
		end
	end
end

function EventHandler.MESSAGE_REACTION_ADD(d, client)
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_REACTION_ADD') end
	local message = channel._messages:get(d.message_id)
	if message then
		local reaction = message:_addReaction(d, d.user_id)
		return client:emit('reactionAdd', reaction, d.user_id)
	else
		return client:emit('reactionAddUncached', channel, d.message_id, d.user_id)
	end
end

function EventHandler.MESSAGE_REACTION_REMOVE(d, client)
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_REACTION_REMOVE') end
	local message = channel._messages:get(d.message_id)
	if message then
		local reaction = message:_removeReaction(d, d.user_id)
		return client:emit('reactionRemove', reaction, d.user_id)
	else
		return client:emit('reactionRemoveUncached', channel, d.message_id, d.user_id)
	end
end

function EventHandler.MESSAGE_REACTION_REMOVE_ALL(d, client)
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'MESSAGE_REACTION_REMOVE_ALL') end
	local message = channel._messages:get(d.message_id)
	if message then
		return client:emit('reactionRemoveAll', message)
	else
		return client:emit('reactionRemoveAllUncached', channel, d.message_id)
	end
end

function EventHandler.CHANNEL_PINS_UPDATE(d, client)
	local channel = getChannel(client, d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'CHANNEL_PINS_UPDATE') end
	return client:emit('pinsUpdate', channel)
end

function EventHandler.PRESENCE_UPDATE(d, client) -- may have incomplete data
	if not d.guild_id then return end -- relationship update
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'PRESENCE_UPDATE') end
	local member = guild._members:get(d.user.id)
	if not member then return end -- joined_at pls
	member:_loadPresence(d)
	member._user:_load(d.user)
	return client:emit('presenceUpdate', member)
end

function EventHandler.TYPING_START(d, client)
	return client:emit('typingStart', d) -- raw data because users are often uncached
end

function EventHandler.USER_UPDATE(d, client)
	client._user:_load(d)
	return client:emit('userUpdate', client._user)
end

function EventHandler.VOICE_STATE_UPDATE() -- TODO
end

function EventHandler.VOICE_SERVER_UPDATE() -- TODO
end

function EventHandler.WEBHOOKS_UPDATE(d, client) -- webhook object is not provided
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'WEBHOOKS_UDPATE') end
	local channel = guild._text_channels:get(d.channel_id)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'WEBHOOKS_UPDATE') end
	return client:emit('webhooksUpdate', channel)
end

return EventHandler
