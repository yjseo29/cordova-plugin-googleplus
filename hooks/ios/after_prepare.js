#!/usr/bin/env node
'use strict';

const fs = require('fs');
const plist = require('plist');
const child_process = require('child_process');
const q = require('q');
const utilities = require('./lib/utilities');

module.exports = function(context) {
  const deferral = q.defer();

  // Step 1: Get the GoogleService-Info.plist path
  const googleServicePlistPath = 'GoogleService-Info.plist';

  // Step 2: Read GoogleService-Info.plist
  console.log("Reading GoogleService-Info.plist...");
  if (!fs.existsSync(googleServicePlistPath)) {
    console.error("GoogleService-Info.plist not found!");
    deferral.reject("GoogleService-Info.plist not found!");
    return deferral.promise;
  }

  const googleServicePlist = plist.parse(fs.readFileSync(googleServicePlistPath, 'utf8'));
  const clientId = googleServicePlist.CLIENT_ID;

  if (!clientId) {
    console.error("CLIENT_ID not found in GoogleService-Info.plist");
    deferral.reject("CLIENT_ID not found in GoogleService-Info.plist");
    return deferral.promise;
  }

  console.log("CLIENT_ID found: ", clientId);

  // Step 3: Get the Info.plist path using Utilities
  const appInfoPlistPath = utilities.getPlistPath(context);

  if (!fs.existsSync(appInfoPlistPath)) {
    console.error("Info.plist not found at: " + appInfoPlistPath);
    deferral.reject("Info.plist not found at: " + appInfoPlistPath);
    return deferral.promise;
  }

  // Step 4: Read and update Info.plist
  console.log("Updating Info.plist...");

  const appInfoPlist = plist.parse(fs.readFileSync(appInfoPlistPath, 'utf8'));

  // Add the CLIENT_ID to the GIDClientID key
  appInfoPlist.GIDClientID = clientId;

  // Step 5: Write the updated Info.plist back
  fs.writeFileSync(appInfoPlistPath, plist.build(appInfoPlist), 'utf8');

  console.log("Successfully updated Info.plist with GIDClientID.");

  deferral.resolve();
  return deferral.promise;
};
