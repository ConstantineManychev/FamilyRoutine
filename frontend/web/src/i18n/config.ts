import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import translationEN from '../../../shared/src/i18n/en.json';
import translationRU from '../../../shared/src/i18n/ru.json';

const resources = {
    en: { translation: translationEN },
    ru: { translation: translationRU }
};

const SUPPORTED_LANGUAGES = Object.keys(resources);
const FALLBACK_LANGUAGE = 'en';
const STORAGE_KEY = 'preferred_language';

const determineInitialLanguage = (): string => {
    const storedLanguage = localStorage.getItem(STORAGE_KEY);
    
    if (storedLanguage && SUPPORTED_LANGUAGES.includes(storedLanguage)) {
        return storedLanguage;
    }

    const systemLanguage = navigator.language.split('-')[0];
    
    if (SUPPORTED_LANGUAGES.includes(systemLanguage)) {
        return systemLanguage;
    }

    return FALLBACK_LANGUAGE;
};

i18n.use(initReactI18next).init({
    resources,
    lng: determineInitialLanguage(),
    fallbackLng: FALLBACK_LANGUAGE,
    interpolation: {
        escapeValue: false
    }
});

i18n.on('languageChanged', (language: string) => {
    localStorage.setItem(STORAGE_KEY, language);
});

export default i18n;