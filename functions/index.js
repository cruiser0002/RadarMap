const { onSchedule } = require("firebase-functions/v2/scheduler");
const { logger } = require("firebase-functions");
const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp({
  databaseURL: "https://radarmap-8adf0-default-rtdb.firebaseio.com"
});

const db = admin.database();

/**
 * 2nd-Gen Scheduled Cloud Function: cleanExpiredRooms
 * Runs every hour to query and purge expired rooms and their corresponding
 * nodes across /r, /t, and /p sub-trees in an atomic multi-path update.
 */
exports.cleanExpiredRooms = onSchedule(
  {
    schedule: "every 1 hours",
    timeZone: "UTC",
    region: "us-central1"
  },
  async (event) => {
    const nowSeconds = Date.now() / 1000;
    logger.info(`Running cleanExpiredRooms. Checking for rooms with expireAt <= ${nowSeconds} (${new Date().toISOString()})`);

    try {
      const snapshot = await db
        .ref("/r")
        .orderByChild("exp")
        .endAt(nowSeconds)
        .once("value");

      const updates = {};
      let expiredCount = 0;

      if (snapshot.exists()) {
        snapshot.forEach((childSnap) => {
          const roomId = childSnap.key;
          const roomData = childSnap.val() || {};
          const expireAt = roomData.exp !== undefined ? roomData.exp : roomData.expireAt;

          if (expireAt !== undefined && expireAt !== null && Number(expireAt) <= nowSeconds) {
            logger.info(`Queueing expired room ${roomId} for deletion (expireAt: ${expireAt})`);
            updates[`/r/${roomId}`] = null;
            updates[`/t/${roomId}`] = null;
            updates[`/p/${roomId}`] = null;
            expiredCount++;
          }
        });
      }

      // Also scan legacy expireAt
      const legacySnap = await db
        .ref("/r")
        .orderByChild("expireAt")
        .endAt(nowSeconds)
        .once("value");

      if (legacySnap.exists()) {
        legacySnap.forEach((childSnap) => {
          const roomId = childSnap.key;
          const roomData = childSnap.val() || {};
          const expireAt = roomData.expireAt;
          if (expireAt !== undefined && expireAt !== null && Number(expireAt) <= nowSeconds && !updates[`/r/${roomId}`]) {
            logger.info(`Queueing legacy expired room ${roomId} for deletion (expireAt: ${expireAt})`);
            updates[`/r/${roomId}`] = null;
            updates[`/t/${roomId}`] = null;
            updates[`/p/${roomId}`] = null;
            expiredCount++;
          }
        });
      }

      if (expiredCount > 0) {
        await db.ref().update(updates);
        logger.info(`Successfully deleted ${expiredCount} expired room(s) across /r, /t, and /p.`);
      } else {
        logger.info("No expired rooms found.");
      }
    } catch (err) {
      logger.error("Error during cleanExpiredRooms execution:", err);
      throw err;
    }
  }
);

/**
 * 1) Empty or Host Departure Room Cleanup Trigger:
 * Triggered on any write/delete to /r/{roomId}/m.
 * If the host leaves or members node becomes empty, automatically deletes the room, tactical, and associated telemetry.
 */
exports.cleanupEmptyRoom = functions.database
  .ref("/r/{roomId}/m")
  .onWrite(async (change, context) => {
    // Early exit if the data was deleted (e.g. room was purged) to prevent cascading writes
    if (!change.after.exists()) {
      return null;
    }

    const roomId = context.params.roomId;
    const membersData = change.after.val();

    // If members node is null or empty, purge room
    if (!membersData || Object.keys(membersData).length === 0) {
      functions.logger.info(`Room ${roomId} has 0 members. Purging room, tactical, and telemetry...`);
      const updates = {};
      updates[`/r/${roomId}`] = null;
      updates[`/t/${roomId}`] = null;
      updates[`/p/${roomId}`] = null;
      await db.ref().update(updates);
      functions.logger.info(`Successfully deleted empty room ${roomId}, tactical, and associated telemetry.`);
      return null;
    }

    // Check if the host has left the room (support both hst and hostId)
    try {
      const roomSnap = await db.ref(`/r/${roomId}`).once("value");
      const roomVal = roomSnap.val() || {};
      const hostId = roomVal.hst || roomVal.hostId;
      if (hostId && !membersData[hostId]) {
        functions.logger.info(`Host ${hostId} has left room ${roomId}. Purging room, tactical, and telemetry...`);
        const updates = {};
        updates[`/r/${roomId}`] = null;
        updates[`/t/${roomId}`] = null;
        updates[`/p/${roomId}`] = null;
        await db.ref().update(updates);
        functions.logger.info(`Successfully purged disbanded room ${roomId} after host departure.`);
        return null;
      }

      // Enforce room max capacity (cap) to protect against internal sabotage / ghost member floods
      const maxCapacity = Number(roomVal.cap) || 12;
      const memberKeys = Object.keys(membersData);

      if (memberKeys.length > maxCapacity) {
        functions.logger.warn(`Room ${roomId} has ${memberKeys.length} members, exceeding cap of ${maxCapacity}. Pruning excess...`);

        // Always protect the host; select excess members from non-hosts
        const nonHostKeys = memberKeys.filter((id) => id !== hostId);
        const allowedNonHostCount = Math.max(0, maxCapacity - (hostId && membersData[hostId] ? 1 : 0));
        const excessKeys = nonHostKeys.slice(allowedNonHostCount);

        if (excessKeys.length > 0) {
          const updates = {};
          for (const excessId of excessKeys) {
            updates[`/r/${roomId}/m/${excessId}`] = null;
            updates[`/p/${roomId}/${excessId}`] = null;
          }
          await db.ref().update(updates);
          functions.logger.info(`Successfully pruned ${excessKeys.length} excess member(s) from room ${roomId}.`);
        }
      }
    } catch (err) {
      functions.logger.error(`Error checking host presence or capacity for room ${roomId}:`, err);
    }

    return null;
  });
