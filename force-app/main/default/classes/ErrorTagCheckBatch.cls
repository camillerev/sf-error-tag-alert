/**
 * @project : CHCCRMB2B2
 * @author : Camille Revol
 * @date : 2025-02-10
 * @description : Batch to check if errors with specific tag increase
 */
public with sharing class ErrorTagCheckBatch implements Database.Batchable<sObject>, Schedulable, Database.Stateful {
	private static String DEFAULT_SETTINGS_NAME = 'DefaultSettings';
	private Integer BATCH_SIZE = 200;
	private String tagName;
	private ErrorTagCheck__c defaultSettingsTagCheck;
	private DateTime newRun;
	private Boolean noError = true;

	/**
	 * @description default constructor
	 * */
	public ErrorTagCheckBatch() {
		this.defaultSettingsTagCheck = ErrorTagCheck__c.getValues(DEFAULT_SETTINGS_NAME);
		this.newRun = DateTime.now();
	}

	/**
	 * @description default constructor with filter on a specific tag Name
	 * @param tagName the tag name
	 */
	public ErrorTagCheckBatch(String tagName) {
		this.defaultSettingsTagCheck = ErrorTagCheck__c.getValues(DEFAULT_SETTINGS_NAME);
		this.newRun = DateTime.now();
		this.tagName = tagName;
	}

	/**
	 * @description query locator for this batch
	 * @param bc batch context
	 * @return database querylocator object
	 */
	public Database.QueryLocator start(Database.BatchableContext bc) {
		DateTime lastRun = this.defaultSettingsTagCheck.LastRunDateTime__c ?? this.newRun;
		//construct the query
		Query q = new Query(LogEntryTag__c.SObjectType)
			.selectFields('Id, Tag__r.Name')
			.addConditionEq('LogEntry__r.LoggingLevel__c', String.valueOf(System.LoggingLevel.ERROR))
			.addConditionGt('LogEntry__r.CreatedDate', lastRun);
		if (String.isNotBlank(tagName)) {
			q.addConditionEq('Tag__r.Name', tagName);
		}
		Logger.fine(q.toQueryString());
		Logger.saveLog();
		return q.getQueryLocator();
	}

	/**
	 * @description batch execution
	 * @param bc batch context
	 * @param loggerEntryTags list of loggerEntryTags retrieved
	 */
	public void execute(Database.BatchableContext bc, List<LogEntryTag__c> loggerEntryTags) {
		try {
			noError = false;
			Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
			List<ErrorTagCheck__c> errorTagCheckToUpsertList = new List<ErrorTagCheck__c>();
			//Get a map of logger tag name with the logger entry tags associated
			Map<String, List<Id>> loggerTagMap = getLoggerTagMap(loggerEntryTags);
			//Get a map of logger tag name with the ErrorTagCheck__c associated if already existing
			Map<String, ErrorTagCheck__c> errorTagsCheckMap = getErrorTagsCheckMap();
			//Get the list of receiver emails (users with email indicated in default record ErrorTagCheck__c)
			Set<Id> sendToUsers = getSendToEmails();
			//For each logger tag name retrieved in the batch, prepare the corresponding ErrorTagCheck__c to upsert
			for (String tag : loggerTagMap.keySet()) {
				ErrorTagCheck__c errorTag = errorTagsCheckMap.get(tag.left(38));
				// Prepare the Error tag check to upsert
				ErrorTagCheck__c errorTagCheckToUpsert = prepareErrorTagCheck(tag, loggerTagMap.get(tag), errorTag);
				Decimal percentageLimit = errorTag?.PercentageLimitAlert__c ?? this.defaultSettingsTagCheck.PercentageLimitAlert__c;
				Decimal minimumErrors = errorTag?.MinimumErrorsAlert__c ?? this.defaultSettingsTagCheck.MinimumErrorsAlert__c;
				// If the following alert conditions are true, prepare the email to be send
				if (
					errorTag != null &&
					this.defaultSettingsTagCheck.IsActive__c &&
					errorTag.IsActive__c &&
					!errorTag.EmailSent__c &&
					errorTagCheckToUpsert.DeltaError__c >= percentageLimit &&
					errorTagCheckToUpsert.ErrorNumber__c >= minimumErrors
				) {
					// Prepare the email to send
					prepareEmailAlert(errorTagCheckToUpsert, message, sendToUsers);
					errorTagCheckToUpsert.EmailSent__c = true;
				} else if (errorTag != null && (errorTagCheckToUpsert.DeltaError__c < percentageLimit || errorTagCheckToUpsert.ErrorNumber__c < minimumErrors)) {
					//if the condition are not true anymore, indicate that no email has been sent for the corresponding tag name
					errorTagCheckToUpsert.EmailSent__c = false;
				}
				errorTagCheckToUpsertList.add(errorTagCheckToUpsert);
			}
			// Prepare the Error tag check that were not in batch because no new error to upsert
			errorTagCheckToUpsertList.addAll(prepareErrorTagChecksNotInBatch(errorTagsCheckMap.values(), loggerTagMap.keySet()));
			errorTagCheckToUpsertList.add(prepareDefaultSettings(loggerEntryTags));
			// Send emails
			sendEmails(message);
			CoreRepository.upsertRecords(errorTagCheckToUpsertList, ErrorTagCheck__c.Name.getDescribe().getSObjectField());
		} catch (Exception e) {
			Logger.error(e.getMessage(), e);
		} finally {
			Logger.saveLog();
		}
	}

	/**
	 * @description at the end of the batch log an entry
	 * @param bc batch context
	 */
	public void finish(Database.BatchableContext bc) {
		if (noError) {
			List<ErrorTagCheck__c> errorTagsCheckList = getErrorTagsCheckMap().values();
			for (ErrorTagCheck__c error : errorTagsCheckList) {
				error.ErrorNumber__c = 0;
				error.LastRunDateTime__c = this.newRun;
				error.NumberOfRun__c += 1;
				error.MeanErrorNumber__c = error.PreviousErrorNumber__c / error.NumberOfRun__c;
				error.DeltaError__c = error.MeanErrorNumber__c != 0 ? (error.ErrorNumber__c - error.MeanErrorNumber__c) / error.MeanErrorNumber__c * 100 : 0;
			}
			errorTagsCheckList.add(new ErrorTagCheck__c(Name = DEFAULT_SETTINGS_NAME, TagName__c = DEFAULT_SETTINGS_NAME, ErrorNumber__c = 0, LastRunDateTime__c = this.newRun));
			CoreRepository.upsertRecords(errorTagsCheckList, ErrorTagCheck__c.Name.getDescribe().getSObjectField());
		}
	}

	/**
	 * @description method to schedule the batch
	 * @param sc schedule context
	 */
	public void execute(SchedulableContext sc) {
		Database.executeBatch(new ErrorTagCheckBatch(), BATCH_SIZE);
	}

	/**
	 * @description getLoggerTagMap Get a map of logger tag name with the logger entry tags associated
	 * @param  loggerEntryTags list of loggerEntryTags retrieved
	 * @return                 return Map<String, List<Id>>
	 */
	private Map<String, List<Id>> getLoggerTagMap(List<LogEntryTag__c> loggerEntryTags) {
		Map<String, List<Id>> loggerTagMap = new Map<String, List<Id>>();
		for (LogEntryTag__c logEntryTag : loggerEntryTags) {
			List<Id> loggerTagIds = loggerTagMap.get(logEntryTag.Tag__r.Name);
			if (loggerTagIds == null) {
				loggerTagIds = new List<Id>();
				loggerTagMap.put(logEntryTag.Tag__r.Name, loggerTagIds);
			}
			loggerTagIds.add(logEntryTag.Id);
		}
		return loggerTagMap;
	}

	/**
	 * @description getErrorTagsCheckMap Get a map of logger tag name with the Error check associated
	 * @return   return Map<String, ErrorTagCheck__c>
	 */
	private Map<String, ErrorTagCheck__c> getErrorTagsCheckMap() {
		Query q = new Query(ErrorTagCheck__c.SObjectType)
			.selectFields('Name, PercentageLimitAlert__c, IsActive__c, NumberOfRun__c, PreviousErrorNumber__c, EmailSent__c, MinimumErrorsAlert__c, TagName__c')
			.addConditionNotEq('Name', DEFAULT_SETTINGS_NAME);
		if (String.isNotBlank(this.tagName)) {
			q.addConditionEq('Name', this.tagName);
		}
		Logger.fine(q.toQueryString());
		List<ErrorTagCheck__c> errorTagsCheckList = (List<ErrorTagCheck__c>) q.run();
		Map<String, ErrorTagCheck__c> errorTagsCheckMap = new Map<String, ErrorTagCheck__c>();
		for (ErrorTagCheck__c errorTagCheck : errorTagsCheckList) {
			errorTagsCheckMap.put(errorTagCheck.Name, errorTagCheck);
		}
		return errorTagsCheckMap;
	}

	/**
	 * @description prepareErrorTagCheck Prepare the Error tag check to upsert
	 * @param  tag               tag tag to check
	 * @param listLoggerTagEntryIds
	 * @param  errorTag errorTag error tag check record
	 * @return                   return ErrorTagCheck__c
	 */
	private ErrorTagCheck__c prepareErrorTagCheck(String tag, List<Id> listLoggerTagEntryIds, ErrorTagCheck__c errorTag) {
		ErrorTagCheck__c errorTagCheckToUpsert = new ErrorTagCheck__c(Name = tag.left(38), TagName__c = tag, ErrorNumber__c = listLoggerTagEntryIds.size(), LastRunDateTime__c = this.newRun);
		if (errorTag != null) {
			errorTagCheckToUpsert.NumberOfRun__c = errorTag.NumberOfRun__c + 1;
			errorTagCheckToUpsert.PreviousErrorNumber__c = errorTag.PreviousErrorNumber__c + errorTagCheckToUpsert.ErrorNumber__c;
			errorTagCheckToUpsert.MeanErrorNumber__c = errorTagCheckToUpsert.PreviousErrorNumber__c / errorTagCheckToUpsert.NumberOfRun__c;
			errorTagCheckToUpsert.DeltaError__c = errorTagCheckToUpsert.MeanErrorNumber__c != 0
				? (errorTagCheckToUpsert.ErrorNumber__c - errorTagCheckToUpsert.MeanErrorNumber__c) / errorTagCheckToUpsert.MeanErrorNumber__c * 100
				: 0;
		} else {
			errorTagCheckToUpsert.NumberOfRun__c = 1;
			errorTagCheckToUpsert.PreviousErrorNumber__c = errorTagCheckToUpsert.ErrorNumber__c;
			errorTagCheckToUpsert.IsActive__c = this.defaultSettingsTagCheck.IsActive__c;
			errorTagCheckToUpsert.PercentageLimitAlert__c = this.defaultSettingsTagCheck.PercentageLimitAlert__c;
			errorTagCheckToUpsert.MinimumErrorsAlert__c = this.defaultSettingsTagCheck.MinimumErrorsAlert__c;
		}
		return errorTagCheckToUpsert;
	}

	/**
	 * @description prepareErrorTagChecksNotInBatch Prepare the Error tag check that were not in batch because no new error to upsert
	 * @param  errorTagsCheckList errorTagsCheckMap
	 * @param  loggerTagSet      loggerTagMap
	 * @return                   return List<ErrorTagCheck__c>
	 */
	public List<ErrorTagCheck__c> prepareErrorTagChecksNotInBatch(List<ErrorTagCheck__c> errorTagsCheckList, Set<String> loggerTagSet) {
		List<ErrorTagCheck__c> errorTagCheckNotInBatchList = new List<ErrorTagCheck__c>();
		for (ErrorTagCheck__c errorTagsCheck : errorTagsCheckList) {
			if (!loggerTagSet.contains(errorTagsCheck.TagName__c)) {
				errorTagsCheck.ErrorNumber__c = 0;
				errorTagsCheck.LastRunDateTime__c = this.newRun;
				errorTagsCheck.NumberOfRun__c += 1;
				errorTagsCheck.EmailSent__c = false;
				errorTagsCheck.MeanErrorNumber__c = errorTagsCheck.PreviousErrorNumber__c / errorTagsCheck.NumberOfRun__c;
				errorTagsCheck.DeltaError__c = errorTagsCheck.MeanErrorNumber__c != 0 ? (errorTagsCheck.ErrorNumber__c - errorTagsCheck.MeanErrorNumber__c) / errorTagsCheck.MeanErrorNumber__c * 100 : 0;
				errorTagCheckNotInBatchList.add(errorTagsCheck);
			}
		}
		return errorTagCheckNotInBatchList;
	}

	/**
	 * @description prepareEmailAlert Prepare the email to send
	 * @param  errorTagCheckToUpsert errorTagCheckToUpsert error tag check with the name of the tag to alert
	 * @param  message               message body to update
	 * @param  sendToUsers      sendToUsers list of receiver users
	 */
	private void prepareEmailAlert(ErrorTagCheck__c errorTagCheckToUpsert, Messaging.SingleEmailMessage message, Set<Id> sendToUsers) {
		if (!sendToUsers.isEmpty()) {
			if (String.isBlank(message.subject)) {
				String orgName = UserInfo.getOrganizationName();
				message.toAddresses = new List<Id>(sendToUsers);
				message.subject = '[' + orgName + '] Alert: The number of errors is increasing';
				message.plainTextBody = 'There is a significant increase in errors regarding the following tags (run time check: ' + this.newRun + '):';
			}
			String body = '\nAlert: The number of errors with the tag ' + errorTagCheckToUpsert.TagName__c + ' increased. Number of errors : ' + errorTagCheckToUpsert.ErrorNumber__c;
			message.plainTextBody += body;
		}
	}

	/**
	 * @description getSendToEmails Get the list of receiver emails
	 * @return   return List<String>
	 */
	private Set<Id> getSendToEmails() {
		List<String> sendToEmailList = this.defaultSettingsTagCheck.EmailList__c.split(';');
		List<User> sendToUsers = new Query(User.SObjectType).selectFields('Id').addConditionIn('Email', sendToEmailList).run();
		return new Map<Id, User>(sendToUsers).keySet();
	}

	/**
	 * @description sendEmails send emails
	 * @param  message message to send
	 */
	private void sendEmails(Messaging.SingleEmailMessage message) {
		List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
		if (!String.isBlank(message.subject)) {
			messages.add(message);
		}
		if (!messages.isEmpty()) {
			Messaging.SendEmailResult[] results = Messaging.sendEmail(messages);
			for (Messaging.SendEmailResult r : results) {
				if (!r.success) {
					Logger.error('The email failed to send: ' + r.errors[0].message);
				}
			}
		}
	}

	/**
	 * @description updateDefaultSettings update the default settings record
	 * @param  loggerEntryTags loggerEntryTags
	 * @return ErrorTagCheck__c
	 */
	private ErrorTagCheck__c prepareDefaultSettings(List<LogEntryTag__c> loggerEntryTags) {
		return new ErrorTagCheck__c(Name = DEFAULT_SETTINGS_NAME, TagName__c = DEFAULT_SETTINGS_NAME, ErrorNumber__c = loggerEntryTags.size(), LastRunDateTime__c = this.newRun);
	}
}