import EventKit
import Foundation

// Напоминание о замене документа в системных «Напоминаниях». Они уходят в
// iCloud, поэтому в напоминании только тип документа и папка — ни номера,
// ни других значений полей
enum ReminderScheduler {
    enum Failure: Error {
        case noDate
        case accessDenied
        case noList
    }

    /// Возвращает момент, на который поставлено напоминание
    static func schedule(
        for document: ChatDocument,
        validity: DocumentValidity,
        now: Date = Date()
    ) async throws -> Date {
        guard let due = dueDate(for: validity, now: now) else { throw Failure.noDate }
        let store = EKEventStore()
        // С iOS 17 доступ к напоминаниям только полный; описание доступа —
        // NSRemindersFullAccessUsageDescription в Info.plist
        guard try await store.requestFullAccessToReminders() else { throw Failure.accessDenied }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }

        let reminder = EKReminder(eventStore: store)
        reminder.title = "Заменить \(document.spokenTitle)"
        reminder.notes = "Файл лежит в LocalDrive, папка «\(document.folder.name)»"
        reminder.calendar = list

        // EventKit требует григорианский календарь в компонентах даты, а на
        // iOS срок без даты начала не сохраняется (EKErrorNoStartDate)
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        components.calendar = calendar
        components.timeZone = .current
        reminder.startDateComponents = components
        reminder.dueDateComponents = components
        reminder.addAlarm(EKAlarm(absoluteDate: due))

        try store.save(reminder, commit: true)
        return due
    }

    /// Загранпаспорт — за полгода до конца срока: для поездок нужен запас в
    /// шесть месяцев. Паспорт РФ — в сам день рождения: на замену подают
    /// после него. Момент уже прошёл — завтра утром
    static func dueDate(for validity: DocumentValidity, now: Date = Date()) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let target: Date
        switch validity.status {
        case .until(let date):
            guard let early = calendar.date(byAdding: .month, value: -6, to: date) else { return nil }
            target = early
        case .replaceAtAge(_, let date):
            target = date
        case .indefinite, .unknown:
            return nil
        }
        guard let due = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: target) else { return nil }
        if due > now { return due }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)
    }
}
