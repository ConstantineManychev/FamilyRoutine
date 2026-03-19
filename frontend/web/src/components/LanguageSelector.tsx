import { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';

const AVAIL_LANGS = [
    { code: 'en', label: 'En' },
    { code: 'ru', label: 'Ru' },
    { code: 'de', label: 'De' },
    { code: 'fr', label: 'Fr' },
    { code: 'es', label: 'Es' },
    { code: 'it', label: 'It' }
];

export const LanguageSelector = () => {
    const { i18n } = useTranslation();
    const [isOpen, setIsOpen] = useState(false);
    const dropRef = useRef<HTMLDivElement>(null);

    const activeLang = AVAIL_LANGS.find(l => l.code === i18n.language) || AVAIL_LANGS[0];

    useEffect(() => {
        const handleOutsideClick = (e: MouseEvent) => {
            if (dropRef.current && !dropRef.current.contains(e.target as Node)) {
                setIsOpen(false);
            }
        };

        document.addEventListener('mousedown', handleOutsideClick);
        return () => document.removeEventListener('mousedown', handleOutsideClick);
    }, []);

    return (
        <div className="relative" ref={dropRef}>
            <button
                type="button"
                onClick={() => setIsOpen(!isOpen)}
                className="w-11 h-11 bg-white/90 hover:bg-white text-gray-800 font-bold rounded-lg shadow-sm transition-colors border border-gray-300 flex items-center justify-center text-sm uppercase"
            >
                {activeLang.code}
            </button>

            {isOpen && (
                <div className="absolute top-full left-0 mt-2 flex flex-col bg-white border border-gray-200 rounded-lg shadow-xl z-[100] min-w-[80px] max-h-[180px] overflow-y-auto">
                    {AVAIL_LANGS.map((lang) => (
                        <button
                            key={lang.code}
                            type="button"
                            className={`block w-full text-center px-4 py-2 text-sm transition-colors hover:bg-blue-50 flex-shrink-0 ${
                                i18n.language === lang.code ? 'text-blue-600 font-bold bg-blue-50/50' : 'text-gray-700'
                            }`}
                            onClick={() => {
                                i18n.changeLanguage(lang.code);
                                setIsOpen(false);
                            }}
                        >
                            {lang.label}
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};