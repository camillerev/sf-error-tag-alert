/**
 * @project : CHCCRMB2B2
 * @author : Camille Revol
 * @date : 2025-02-10
 * @description : Test class for ErrorTagCheckBatch
 */
@IsTest
public with sharing class ErrorTagCheckBatchTest {
	private static String adminUsername = '%Global_Super_Admin%@' + UserInfo.getOrganizationId() + '.com';
	@TestSetup
	static void makeData() {
		TestDataFactory.createUsers('CHC - Administrator', null, 1, 'CHC_Global_Super_Admin', false);
	}

	@isTest
	static void checkErrorTagTest() {
		User admin = TestDataFactory.getUserLikeUsername(adminUsername)[0];
		Test.startTest();
		System.runAs(admin) {
			List<ErrorTagCheck__c> listErrorCheck = new List<ErrorTagCheck__c>();
			listErrorCheck.add(
				new ErrorTagCheck__c(
					Name = 'DefaultSettings',
					TagName__c = 'DefaultSettings',
					PercentageLimitAlert__c = 1,
					MinimumErrorsAlert__c = 2,
					IsActive__c = true,
					LastRunDateTime__c = DateTime.now().addMinutes(-10),
					EmailList__c = 'standarduser@testorg.com'
				)
			);
			listErrorCheck.add(
				new ErrorTagCheck__c(
					Name = 'Callout:TEST2',
					TagName__c = 'Callout:TEST2',
					PercentageLimitAlert__c = 1,
					MinimumErrorsAlert__c = 2,
					IsActive__c = true,
					LastRunDateTime__c = DateTime.now().addMinutes(-10),
					EmailList__c = 'test@test.com',
					NumberOfRun__c = 1,
					PreviousErrorNumber__c = 2,
					ErrorNumber__c = 2
				)
			);
			listErrorCheck.add(
				new ErrorTagCheck__c(
					Name = 'Callout:TEST3',
					TagName__c = 'Callout:TEST3',
					PercentageLimitAlert__c = 1,
					MinimumErrorsAlert__c = 2,
					IsActive__c = true,
					LastRunDateTime__c = DateTime.now().addMinutes(-10),
					EmailList__c = 'test@test.com',
					NumberOfRun__c = 1,
					PreviousErrorNumber__c = 50,
					ErrorNumber__c = 50
				)
			);
			insert listErrorCheck;

			List<LoggerTag__c> listTag = new List<LoggerTag__c>();
			LoggerTag__c tag1 = new LoggerTag__c(Name = 'Callout:TEST1');
			LoggerTag__c tag2 = new LoggerTag__c(Name = 'Callout:TEST2');
			LoggerTag__c tag3 = new LoggerTag__c(Name = 'Callout:TEST3');
			listTag.add(tag1);
			listTag.add(tag2);
			insert new List<LoggerTag__c>{ tag1, tag2, tag3 };

			createLogEntries(3, listTag);
			try {
				Database.executeBatch(new ErrorTagCheckBatch());
				Database.executeBatch(new ErrorTagCheckBatch('Callout:TEST1'));
				System.schedule('ErrorTagCheckBatch', '0 0 0 * * ?', new ErrorTagCheckBatch());
			} catch (Exception e) {
				String exceptionThrown = e.getMessage();
			}
			Test.stopTest();
			List<ErrorTagCheck__c> results = [
				SELECT
					Id,
					Name,
					ErrorNumber__c,
					MeanErrorNumber__c,
					PreviousErrorNumber__c,
					NumberOfRun__c,
					DeltaError__c,
					PercentageLimitAlert__c,
					MinimumErrorsAlert__c,
					EmailSent__c,
					IsActive__c,
					LastRunDateTime__c,
					EmailList__c
				FROM ErrorTagCheck__c
				WHERE Name IN ('Callout:TEST1', 'Callout:TEST2', 'Callout:TEST3')
			];
			System.assertEquals(3, results.size(), 'The size of te list must be 3');
			Map<String, ErrorTagCheck__c> mapResults = new Map<String, ErrorTagCheck__c>();
			for (ErrorTagCheck__c res : results) {
				mapResults.put(res.Name, res);
			}
			System.assertEquals(3, mapResults.get('Callout:TEST1').ErrorNumber__c, 'The ErrorNumber__c value for tag Callout:TEST1 must be 3');
			System.assertEquals(3, mapResults.get('Callout:TEST2').ErrorNumber__c, 'The ErrorNumber__c value for tag Callout:TEST2 must be 3');
			System.assertEquals(0, mapResults.get('Callout:TEST3').ErrorNumber__c, 'The ErrorNumber__c value for tag Callout:TEST3 must be 0');
		}
	}

	private static void createLogEntries(Integer numberLogs, List<LoggerTag__c> listTag) {
		Log__c log = new Log__c();
		insert log;
		List<LogEntry__c> listLogEntry = new List<LogEntry__c>();
		for (Integer i = 0; i < numberLogs; i++) {
			listLogEntry.add(new LogEntry__c(Log__c = log.Id, LoggingLevel__c = String.valueOf(System.LoggingLevel.ERROR)));
		}
		insert listLogEntry;
		List<LogEntryTag__c> listLogEntryTag = new List<LogEntryTag__c>();
		for (LoggerTag__c tag : listTag) {
			for (Integer i = 0; i < numberLogs; i++) {
				listLogEntryTag.add(new LogEntryTag__c(Tag__c = tag.Id, LogEntry__c = listLogEntry[i].Id));
			}
		}
		insert listLogEntryTag;
	}
}